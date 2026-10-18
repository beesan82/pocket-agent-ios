import PocketAgentCore
import SwiftUI

/// Navigation root: the conversation list is home.
struct ContentView: View {
    let settings: ModelSettings
    let credentials: any CredentialStore
    let availability: any ModelAvailabilityChecking
    let mlxStore: MLXModelStore
    let mlxRuntime: MLXRuntime
    let measurementLog: MeasurementLog
    let developer: DeveloperSettings
    let tokenStore: any CredentialStore

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ConversationListView(
                path: $path, settings: settings, credentials: credentials, availability: availability,
                mlxStore: mlxStore, mlxRuntime: mlxRuntime, measurementLog: measurementLog,
                developer: developer, tokenStore: tokenStore)
        }
    }
}
