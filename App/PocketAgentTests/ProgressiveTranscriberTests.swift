import Foundation
import Speech
import Testing
@testable import PocketAgent

struct ProgressiveTranscriberTests {
    @Test func composedReportingOptionsAddAlternatives() {
        #expect(ProgressiveTranscriber.reportingOptions.contains(.alternativeTranscriptions))
    }

    @Test func composedReportingOptionsKeepThePresetOptions() {
        let preset = SpeechTranscriber.Preset.progressiveTranscription.reportingOptions
        #expect(preset.isSubset(of: ProgressiveTranscriber.reportingOptions))
        #expect(ProgressiveTranscriber.reportingOptions.count == preset.count + 1)
    }

    /// Task 0 fact check: the composition Apple's preset table documents for
    /// `.progressiveTranscription` — volatile + fast results, no alternatives,
    /// no audio time range. Recorded in
    /// docs/superpowers/plans/2026-11-04-term-accuracy.md.
    @Test func progressivePresetCompositionMatchesTheDocumentedTable() {
        let preset = SpeechTranscriber.Preset.progressiveTranscription
        #expect(preset.reportingOptions.contains(.volatileResults))
        #expect(preset.reportingOptions.contains(.fastResults))
        #expect(!preset.reportingOptions.contains(.alternativeTranscriptions))
        #expect(!preset.attributeOptions.contains(.audioTimeRange))
    }

    @Test func builderConstructsATranscriber() {
        _ = ProgressiveTranscriber.make(locale: Locale(identifier: "ja_JP"))
    }

    /// Task 0 probe: prints the live option sets so the CI log records what
    /// the shipping SDK actually composes (never guessed — plan Task 0).
    @Test func probePresetComposition() {
        let preset = SpeechTranscriber.Preset.progressiveTranscription
        print("PROBE progressive transcriptionOptions=\(preset.transcriptionOptions)")
        print("PROBE progressive reportingOptions=\(preset.reportingOptions)")
        print("PROBE progressive attributeOptions=\(preset.attributeOptions)")
        let withAlternatives = SpeechTranscriber.Preset.transcriptionWithAlternatives
        print("PROBE withAlternatives transcriptionOptions=\(withAlternatives.transcriptionOptions)")
        print("PROBE withAlternatives reportingOptions=\(withAlternatives.reportingOptions)")
        print("PROBE withAlternatives attributeOptions=\(withAlternatives.attributeOptions)")
        print("PROBE composed reportingOptions=\(ProgressiveTranscriber.reportingOptions)")
    }
}
