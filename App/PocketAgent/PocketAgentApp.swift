import SwiftUI

@main
struct PocketAgentApp: App {
    @State private var settings = ModelSettings()

    var body: some Scene {
        WindowGroup {
            ContentView(
                settings: settings,
                credentials: KeychainCredentialStore(),
                availability: AppleLocalAvailability()
            )
        }
    }
}
