import Foundation
import Observation
import PocketAgentCore

// RED stub
@MainActor
@Observable
final class ModelSettings {
    var choice: ModelChoice = .appleLocal
    var claudeModel: String = ""

    init(defaults _: UserDefaults = .standard) {}
}
