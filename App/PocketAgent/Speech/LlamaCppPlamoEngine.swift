import Foundation
import llama
import PocketAgentCore

/// PLaMo 3 Translate on llama.cpp (ADR-051). Each call loads the GGUF, generates, and frees
/// everything again, so the ~570 MB model never stays resident between translations (ADR-050).
final class LlamaCppPlamoEngine: PlamoInferenceEngine, @unchecked Sendable {
    static let maxGeneratedTokens = 1024
    static let contextSize = 2048

    private let modelURL: URL
    /// llama objects are not thread-safe; one serial queue also keeps two loads from overlapping.
    private let queue = DispatchQueue(label: "jp.pocketagent.plamo-llama-cpp")

    init(modelURL: URL) {
        self.modelURL = modelURL
    }

    convenience init() {
        self.init(modelURL: Self.defaultModelURL())
    }

    /// The file PlamoModelStore downloads.
    static func defaultModelURL() -> URL {
        HubPlamoDownloader.directory(of: PlamoModel.translate08B, at: MLXModelStore.baseDirectory)
            .appending(path: PlamoModel.translate08B.fileName)
    }

    func generate(prompt: String) async throws -> String {
        let modelURL = modelURL
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try Self.run(modelURL: modelURL, prompt: prompt) })
            }
        }
    }

    /// Initialises the llama backend once per process and silences its logging.
    private static let backend: Void = {
        llama_backend_init()
        llama_log_set({ _, _, _ in }, nil)
    }()

    private static func run(modelURL: URL, prompt: String) throws -> String {
        let path = modelURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            throw PlamoTranslatorError.modelNotDownloaded
        }
        _ = backend

        var modelParams = llama_model_default_params()
        #if !targetEnvironment(simulator)
        // Offload every layer to Metal on device; the simulator stays on the CPU.
        modelParams.n_gpu_layers = 99
        #endif
        guard let model = llama_model_load_from_file(path, modelParams) else {
            throw PlamoTranslatorError.inferenceFailed
        }
        defer { llama_model_free(model) }
        guard let vocab = llama_model_get_vocab(model) else {
            throw PlamoTranslatorError.inferenceFailed
        }

        var promptTokens = try tokenize(vocab: vocab, text: prompt, addSpecial: true)
        guard !promptTokens.isEmpty, promptTokens.count < contextSize else {
            throw PlamoTranslatorError.inferenceFailed
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextSize)
        contextParams.n_batch = UInt32(contextSize)
        guard let context = llama_init_from_model(model, contextParams) else {
            throw PlamoTranslatorError.inferenceFailed
        }
        defer { llama_free(context) }

        let prefill = llama_decode(
            context, llama_batch_get_one(&promptTokens, Int32(promptTokens.count)))
        guard prefill == 0 else { throw PlamoTranslatorError.inferenceFailed }

        // Greedy (temperature 0), the configuration verified on the VM.
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw PlamoTranslatorError.inferenceFailed
        }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var stopTokens = Set<llama_token>()
        for marker in PlamoPrompt.stopMarkers {
            stopTokens.formUnion(try tokenize(vocab: vocab, text: marker, addSpecial: false))
        }

        // Never run past the context window: the prompt already occupies part of it.
        let limit = min(maxGeneratedTokens, contextSize - promptTokens.count)
        // Pieces are collected as bytes and decoded once, so multi-byte characters split
        // across pieces come out whole.
        var output = Data()
        for _ in 0..<limit {
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) || stopTokens.contains(token) { break }
            output.append(piece(vocab: vocab, token: token))
            let status = withUnsafeMutablePointer(to: &token) { pointer in
                llama_decode(context, llama_batch_get_one(pointer, 1))
            }
            guard status == 0 else { throw PlamoTranslatorError.inferenceFailed }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// parse_special is always on: `<|plamo:tag|>` and friends must become special tokens,
    /// otherwise the PFML3 prompt falls apart.
    private static func tokenize(vocab: OpaquePointer, text: String, addSpecial: Bool) throws -> [llama_token] {
        let length = Int32(text.utf8.count)
        // With no buffer, llama_tokenize returns the negated token count it needs.
        let needed = llama_tokenize(vocab, text, length, nil, 0, addSpecial, true)
        let capacity = Int(needed < 0 ? -needed : needed)
        guard capacity > 0 else { return [] }
        var tokens = [llama_token](repeating: 0, count: capacity)
        let count = llama_tokenize(
            vocab, text, length, &tokens, Int32(tokens.count), addSpecial, true)
        guard count >= 0 else { throw PlamoTranslatorError.inferenceFailed }
        return Array(tokens.prefix(Int(count)))
    }

    private static func piece(vocab: OpaquePointer, token: llama_token) -> Data {
        var buffer = [CChar](repeating: 0, count: 64)
        var written = buffer.withUnsafeMutableBufferPointer { pointer in
            llama_token_to_piece(vocab, token, pointer.baseAddress, Int32(pointer.count), 0, true)
        }
        if written < 0 {
            // A negative result is the negated size the piece needs.
            buffer = [CChar](repeating: 0, count: Int(-written))
            written = buffer.withUnsafeMutableBufferPointer { pointer in
                llama_token_to_piece(vocab, token, pointer.baseAddress, Int32(pointer.count), 0, true)
            }
        }
        guard written > 0 else { return Data() }
        return Data(buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) })
    }
}
