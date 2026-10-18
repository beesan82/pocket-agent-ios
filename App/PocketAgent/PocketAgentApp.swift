import SwiftData
import SwiftUI

@main
struct PocketAgentApp: App {
    @State private var settings = ModelSettings()
    @State private var container = try? AppModelContainer.make()
    private let credentials = KeychainCredentialStore()
    private let availability = AppleLocalAvailability()

    var body: some Scene {
        WindowGroup {
            if let container {
                ContentView(settings: settings, credentials: credentials, availability: availability)
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
