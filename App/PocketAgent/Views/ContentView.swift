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
    let meeting: MeetingSession

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RootTabView(
            settings: settings, credentials: credentials, availability: availability,
            mlxStore: mlxStore, mlxRuntime: mlxRuntime, measurementLog: measurementLog,
            developer: developer, tokenStore: tokenStore, journal: journal, meeting: meeting)
            // Watched here, not in the meeting tab: notes catch up on return whichever tab is open.
            .onChange(of: scenePhase, initial: true) { _, phase in
                meeting.setForeground(phase == .active)
            }
    }
}
