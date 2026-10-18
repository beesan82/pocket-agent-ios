import SwiftData
import SwiftUI

@main
struct PocketAgentApp: App {
    @State private var settings = ModelSettings()
    @State private var mlxStore: MLXModelStore
    @State private var mlxRuntime: MLXRuntime
    @State private var container: ModelContainer?
    private let credentials = KeychainCredentialStore()
    private let availability = AppleLocalAvailability()

    init() {
        // One store and one runtime for the whole app; the runtime reads the store's directory.
        let store = MLXModelStore()
        _mlxStore = State(initialValue: store)
        _mlxRuntime = State(initialValue: MLXRuntime(store: store))

        let container = try? AppModelContainer.make()
        if let container {
            // Once per launch; a failed run leaves its flag unset and retries next launch.
            try? NoteMigration.migrateOnce(context: container.mainContext, defaults: .standard)
        }
        _container = State(initialValue: container)
    }

    var body: some Scene {
        WindowGroup {
            if let container {
                ContentView(
                    settings: settings, credentials: credentials, availability: availability,
                    mlxStore: mlxStore, mlxRuntime: mlxRuntime)
                    .modelContainer(container)
            } else {
                // Fixed text: the underlying error is never shown.
                ContentUnavailableView(
                    "データを開けませんでした",
                    systemImage: "exclamationmark.triangle",
                    description: Text("アプリを再起動してください。解決しない場合は再インストールが必要です。"))
            }
        }
    }
}
