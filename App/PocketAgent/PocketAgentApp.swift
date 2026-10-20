import SwiftData
import SwiftUI

@main
struct PocketAgentApp: App {
    @State private var settings: ModelSettings
    @State private var mlxStore: MLXModelStore
    @State private var mlxRuntime: MLXRuntime
    @State private var container: ModelContainer?
    /// The one journal store for the app (a second instance could hand out duplicate sequences).
    @State private var journal: SwiftDataJournalStore?
    private let credentials: KeychainCredentialStore
    private let availability = AppleLocalAvailability()
    private let measurementLog: MeasurementLog
    /// The one download flow: both the settings list and the detailed models screen drive it.
    @State private var downloadFlow: ModelDownloadFlow
    @State private var developer = DeveloperSettings()
    private let tokenStore = KeychainCredentialStore(
        service: "com.beesan82.pocketagent.github", account: "measurement-token")

    init() {
        let credentials = KeychainCredentialStore()
        self.credentials = credentials
        let settings = ModelSettings()
        // Once per install: a Claude choice without an API key moves to the downloaded model.
        settings.migrateDefaultModelIfNeeded(credentials: credentials)
        _settings = State(initialValue: settings)

        // One store and one runtime for the whole app; the runtime reads the store's directory.
        let store = MLXModelStore()
        _mlxStore = State(initialValue: store)
        _mlxRuntime = State(initialValue: MLXRuntime(store: store))
        let log = MeasurementLog()
        measurementLog = log
        _downloadFlow = State(initialValue: ModelDownloadFlow(store: store, measurementLog: log))

        let container = try? AppModelContainer.make()
        if let container {
            // Once per launch; a failed run leaves its flag unset and retries next launch.
            try? NoteMigration.migrateOnce(context: container.mainContext, defaults: .standard)
        }
        _container = State(initialValue: container)
        _journal = State(initialValue: container.map { SwiftDataJournalStore(modelContainer: $0) })
    }

    var body: some Scene {
        WindowGroup {
            if let container, let journal {
                ContentView(
                    settings: settings, credentials: credentials, availability: availability,
                    mlxStore: mlxStore, mlxRuntime: mlxRuntime, measurementLog: measurementLog,
                    developer: developer, tokenStore: tokenStore, journal: journal)
                    .modelContainer(container)
                    .environment(downloadFlow)
                    // The only presenter of the download / delete confirmations.
                    .modelDownloadDialogs(downloadFlow)
                    // Logged once here, not per screen (Settings and the models screen share the flow).
                    .onChange(of: downloadFlow.statusSnapshot) { old, new in
                        downloadFlow.logDownloadTransitions(from: old, to: new)
                    }
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
