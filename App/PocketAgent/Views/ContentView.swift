import PocketAgentCore
import SwiftUI

/// Navigation root: the tabs (journal is home).
struct ContentView: View {
    let settings: ModelSettings
    let credentials: any CredentialStore
    let availability: any ModelAvailabilityChecking
    let mlxStore: MLXModelStore
    let mlxRuntime: MLXRuntime
    let measurementLog: MeasurementLog
    let developer: DeveloperSettings
    let tokenStore: any CredentialStore
    let journal: any JournalStore

    var body: some View {
        RootTabView(
            settings: settings, credentials: credentials, availability: availability,
            mlxStore: mlxStore, mlxRuntime: mlxRuntime, measurementLog: measurementLog,
            developer: developer, tokenStore: tokenStore, journal: journal)
    }
}
