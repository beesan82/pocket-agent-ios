import Foundation

/// Structural checks only: never contacts the Hub or reads tensor payloads into memory.
enum ModelFileValidator {
    // The safetensors format's header limit also bounds malformed JSON assets before allocation.
    private static let maximumJSONBytes: UInt64 = 100_000_000

    static func isComplete(at directory: URL) -> Bool {
        guard let config = jsonObject(at: directory.appending(path: "config.json")),
              hasTokenizer(at: directory, config: config),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return false }

        let weights = files.filter { $0.pathExtension == "safetensors" }
        guard !weights.isEmpty else { return false }
        var tensorsByFile: [String: Set<String>] = [:]
        for file in weights {
            guard let tensors = tensorNames(at: file) else { return false }
            tensorsByFile[file.lastPathComponent] = tensors
        }

        // A missing shard must not be hidden by another valid .safetensors file.
        for index in files where index.lastPathComponent.hasSuffix(".safetensors.index.json") {
            guard let object = jsonObject(at: index),
                  let map = object["weight_map"] as? [String: String], !map.isEmpty
            else { return false }
            for (tensor, file) in map {
                guard !file.contains("/"), !file.contains("\\"),
                      tensorsByFile[file]?.contains(tensor) == true
                else { return false }
            }
        }
        return true
    }

    private static func hasTokenizer(at directory: URL, config: [String: Any]) -> Bool {
        // The pinned swift-transformers loader reads tokenizer.json, including for SentencePiece
        // models. A .model or vocab.txt file alone cannot satisfy that loader.
        guard let tokenizer = jsonObject(at: directory.appending(path: "tokenizer.json")),
              let model = tokenizer["model"] as? [String: Any],
              let type = model["type"] as? String, !type.isEmpty
        else { return false }
        if type == "Unigram" {
            guard let vocabulary = model["vocab"] as? [[Any]], !vocabulary.isEmpty,
                  vocabulary.allSatisfy({ $0.count == 2 && $0[0] is String && $0[1] is NSNumber })
            else { return false }
        } else {
            guard let vocabulary = model["vocab"] as? [String: Int], !vocabulary.isEmpty,
                  vocabulary.values.allSatisfy({ $0 >= 0 })
            else { return false }
            if type == "BPE" {
                // Tokenizers JSON uses either legacy "a b" strings or modern ["a", "b"] pairs.
                guard let merges = model["merges"] as? [Any], merges.allSatisfy({
                    if let pair = $0 as? [String] { return pair.count == 2 }
                    if let pair = $0 as? String { return pair.split(separator: " ").count == 2 }
                    return false
                }) else { return false }
            }
        }

        let configurationURL = directory.appending(path: "tokenizer_config.json")
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            return jsonObject(at: configurationURL) != nil
        }
        // These are the two local configuration fallbacks bundled by swift-transformers 1.3.5.
        // Qwen models in the registry need their downloaded tokenizer_config.json.
        return ["gpt2", "t5"].contains(config["model_type"] as? String ?? "")
    }

    private static func jsonObject(at url: URL) -> [String: Any]? {
        guard let data = boundedData(at: url),
              let value = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return value as? [String: Any]
    }

    private static func boundedData(at url: URL) -> Data? {
        guard let handle = regularFile(at: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0, size <= maximumJSONBytes,
              (try? handle.seek(toOffset: 0)) != nil,
              let data = try? handle.read(upToCount: Int(size)), data.count == Int(size)
        else { return nil }
        return data
    }

    private static func regularFile(at url: URL) -> FileHandle? {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { return nil }
        return try? FileHandle(forReadingFrom: url)
    }

    private static func tensorNames(at url: URL) -> Set<String>? {
        guard let handle = regularFile(at: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 8,
              (try? handle.seek(toOffset: 0)) != nil,
              let prefix = try? handle.read(upToCount: 8), prefix.count == 8
        else { return nil }
        // Decode bytewise: Data's storage is not guaranteed to have UInt64 alignment.
        let headerLength = prefix.enumerated().reduce(UInt64(0)) {
            $0 | UInt64($1.element) << ($1.offset * 8)
        }
        guard headerLength > 0, headerLength <= maximumJSONBytes, headerLength <= size - 8,
              let data = try? handle.read(upToCount: Int(headerLength)), data.count == Int(headerLength),
              data.first == UInt8(ascii: "{"),
              let header = try? JSONDecoder().decode(Header.self, from: data), !header.tensors.isEmpty
        else { return nil }

        let payloadSize = size - 8 - headerLength
        var ranges: [(start: UInt64, end: UInt64)] = []
        for tensor in header.tensors.values {
            guard let elementBytes = bytesPerElement[tensor.dtype], tensor.dataOffsets.count == 2
            else { return nil }
            var elements: UInt64 = 1
            for dimension in tensor.shape {
                let product = elements.multipliedReportingOverflow(by: dimension)
                guard !product.overflow else { return nil }
                elements = product.partialValue
            }
            let byteCount = elements.multipliedReportingOverflow(by: elementBytes)
            let start = tensor.dataOffsets[0]
            let end = tensor.dataOffsets[1]
            guard !byteCount.overflow, start <= end, end <= payloadSize,
                  end - start == byteCount.partialValue
            else { return nil }
            ranges.append((start, end))
        }
        // Safetensors requires the tensor ranges to cover the payload without holes or overlap.
        ranges.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var end: UInt64 = 0
        for range in ranges {
            guard range.start == end else { return nil }
            end = range.end
        }
        guard end == payloadSize else { return nil }
        return Set(header.tensors.keys)
    }

    private static let bytesPerElement: [String: UInt64] = [
        "BOOL": 1, "U8": 1, "I8": 1, "F8_E4M3": 1, "F8_E5M2": 1,
        "U16": 2, "I16": 2, "F16": 2, "BF16": 2,
        "U32": 4, "I32": 4, "F32": 4,
        "U64": 8, "I64": 8, "F64": 8,
    ]

    private struct Tensor: Decodable {
        let dtype: String
        let shape: [UInt64]
        let dataOffsets: [UInt64]

        enum CodingKeys: String, CodingKey {
            case dtype, shape
            case dataOffsets = "data_offsets"
        }
    }

    private struct Header: Decodable {
        let tensors: [String: Tensor]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            var tensors: [String: Tensor] = [:]
            for key in container.allKeys {
                if key.stringValue == "__metadata__" {
                    _ = try container.decode([String: String].self, forKey: key)
                } else {
                    tensors[key.stringValue] = try container.decode(Tensor.self, forKey: key)
                }
            }
            self.tensors = tensors
        }

        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
    }
}
