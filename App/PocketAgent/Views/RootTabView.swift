import PocketAgentCore
import SwiftUI

/// Root tabs: 日誌 (home), 聞く, チャット. Each tab has its own navigation stack.
struct RootTabView: View {
    let settings: ModelSettings
    let credentials: any CredentialStore
    let availability: any ModelAvailabilityChecking
    let mlxStore: MLXModelStore
    let mlxRuntime: MLXRuntime
    let measurementLog: MeasurementLog
    let developer: DeveloperSettings
    let tokenStore: any CredentialStore
    /// The app's single journal store, shared by every screen.
    let journal: any JournalStore

    @State private var chatPath = NavigationPath()

    var body: some View {
        TabView {
            Tab("日誌", systemImage: "book") {
                NavigationStack {
                    JournalView(
                        journal: journal, settings: settings, availability: availability,
                        mlxStore: mlxStore, mlxRuntime: mlxRuntime,
                        measurementLog: measurementLog, settingsView: settingsView)
                }
            }
            Tab("聞く", systemImage: "bubble.left.and.text.bubble.right") {
                NavigationStack {
                    AskJournalView(
                        journal: journal, settings: settings, availability: availability,
                        mlxStore: mlxStore, mlxRuntime: mlxRuntime,
                        measurementLog: measurementLog, settingsView: settingsView)
                }
            }
            Tab("チャット", systemImage: "message") {
                NavigationStack(path: $chatPath) {
                    ConversationListView(
                        path: $chatPath, settings: settings, credentials: credentials, availability: availability,
                        mlxStore: mlxStore, mlxRuntime: mlxRuntime, measurementLog: measurementLog,
                        developer: developer, tokenStore: tokenStore, journal: journal)
                }
            }
        }
    }

    private var settingsView: SettingsView {
        SettingsView(
            settings: settings, credentials: credentials, availability: availability,
            mlxStore: mlxStore, mlxRuntime: mlxRuntime, measurementLog: measurementLog,
            developer: developer, tokenStore: tokenStore, journal: journal)
    }
}
