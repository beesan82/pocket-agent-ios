import ClaudeForFoundationModels
import FoundationModels
import SwiftUI
import UIKit

@main
struct FMHarnessApp: App {
    var body: some Scene {
        WindowGroup { SpikeView() }
    }
}

struct SpikeView: View {
    @State private var log = SpikeLog()
    @State private var notes = NoteBox()
    @State private var approvals = ApprovalCenter()
    @State private var backend: Backend = .claudeAPIKey
    @State private var sessions: [Backend: LanguageModelSession] = [:]
    @State private var prompt = "私の名前はケイタ 覚えておいて"
    @State private var running: Task<Void, Never>?
    @State private var apiKeyInput = ""
    @AppStorage("spike.clientID") private var clientID = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("端末") {
                    Text("\(Probes.deviceModel()) / iOS \(UIDevice.current.systemVersion)")
                    Text("SystemLanguageModel: \(String(describing: SystemLanguageModel.default.availability))")
                        .font(.caption)
                }
                Section("バックエンド") {
                    Picker("モデル", selection: $backend) {
                        ForEach(Backend.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if backend == .claudeAPIKey {
                        Text(SpikeKeychain.readAPIKey() == nil ? "Keychain: キーなし" : "Keychain: キーあり")
                        SecureField("API キーを Keychain に保存", text: $apiKeyInput)
                        Button("保存") {
                            let status = SpikeKeychain.save(apiKeyInput)
                            apiKeyInput = ""
                            log.add("Keychain save status=\(status)")
                        }
                    }
                    if backend == .claudeAppAttest {
                        TextField("client ID (clid_…)", text: $clientID)
                            .textInputAutocapitalization(.never)
                        Button("authenticateIfNeeded()") { authenticate() }
                    }
                    if backend == .mlx {
                        Button("モデルを読み込む (preload)") { preloadMLX() }
                    }
                    Button("新しいセッション（トランスクリプト破棄）") {
                        sessions[backend] = nil
                        log.add("\(backend.rawValue): session reset")
                    }
                }
                Section("送信") {
                    TextField("プロンプト", text: $prompt, axis: .vertical)
                    HStack {
                        Button("送信") { send() }.disabled(running != nil)
                        Spacer()
                        Button("キャンセル", role: .destructive) { running?.cancel() }
                            .disabled(running == nil)
                    }
                }
                Section("保存されたメモ (\(notes.notes.count))") {
                    ForEach(notes.notes, id: \.self) { Text($0) }
                }
                Section("ログ") {
                    Button("ログをコピー") { UIPasteboard.general.string = log.text }
                    Button("ログを消す") { log.clear() }
                    ForEach(Array(log.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("FM Spike")
            .sheet(item: Binding(get: { approvals.request }, set: { _ in })) { request in
                VStack(spacing: 16) {
                    Text("\(request.toolName) の承認").font(.headline)
                    Text(request.summary)
                    HStack {
                        Button("拒否", role: .cancel) { approvals.resolve(false) }
                        Button("保存する") { approvals.resolve(true) }.buttonStyle(.borderedProminent)
                    }
                    // Item 4: cancel the whole respond() while Tool.call is still waiting.
                    Button("応答をキャンセル（承認待ちのまま）", role: .destructive) { running?.cancel() }
                        .font(.footnote)
                }
                .padding()
                .presentationDetents([.medium])
                .interactiveDismissDisabled()
            }
        }
    }

    private func send() {
        let backend = backend
        let text = prompt
        let session: LanguageModelSession
        do {
            if let existing = sessions[backend] {
                session = existing
            } else {
                let tool = SaveNoteTool(approvals: approvals, notes: notes, log: log)
                session = try makeSession(backend, tools: [tool], clientID: clientID)
                sessions[backend] = session
                log.add("\(backend.rawValue): new session")
            }
        } catch {
            log.add("\(backend.rawValue): setup error \(error)")
            return
        }
        log.add("\(backend.rawValue) → \(text)")
        running = Task {
            let started = Date()
            do {
                let response = try await session.respond(to: text)
                log.add("← \(response.content)")
            } catch is CancellationError {
                log.add("respond threw CancellationError")
            } catch {
                log.add("respond error: \(String(reflecting: error))")
            }
            log.add(String(format: "elapsed %.1fs, isResponding=%@, %@", Date().timeIntervalSince(started),
                           String(session.isResponding), transcriptSummary(session)))
            if backend == .mlx { log.add(Probes.memorySummary()) }
            running = nil
        }
    }

    private func authenticate() {
        let model = claudeModel(auth: .appAttest(clientID: clientID))
        log.add("appAttest authenticateIfNeeded start")
        Task {
            do {
                try await model.authenticateIfNeeded()
                log.add("appAttest authenticateIfNeeded OK")
            } catch {
                log.add("appAttest error: \(String(reflecting: error))")
            }
        }
    }

    private func preloadMLX() {
        #if targetEnvironment(simulator)
        log.add("MLX: simulator")
        #else
        log.add("MLX preload start; \(Probes.memorySummary())")
        Task {
            let started = Date()
            do {
                try await mlxModel.preload()
                log.add(String(format: "MLX preload OK %.1fs; ", Date().timeIntervalSince(started))
                        + Probes.memorySummary())
            } catch {
                log.add("MLX preload error: \(String(reflecting: error))")
            }
        }
        #endif
    }
}
