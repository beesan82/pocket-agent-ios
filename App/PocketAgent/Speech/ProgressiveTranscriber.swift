import Foundation
import Speech

/// Shared builders for the single-language (progressive) `SpeechTranscriber`,
/// so the live capture and the auto check can never drift apart (ADR-044).
///
/// The standard configuration is the `.progressiveTranscription` preset
/// itself, unchanged. The composed configuration takes the preset's option
/// sets and adds `.alternativeTranscriptions` to the reporting options —
/// the preset has no variant with both progressive reporting (volatile and
/// fast results, which the live display needs) and alternatives, and the
/// `.transcriptionWithAlternatives` preset drops the progressive reporting.
/// Experiment 1 (term accuracy) runs on the composed configuration; the
/// live path switches to it only if the experiment is adopted.
enum ProgressiveTranscriber {
    /// The preset's reporting options plus `.alternativeTranscriptions`.
    /// (The SDK models each option group as a `Set` of enum cases —
    /// `Preset.reportingOptions: Set<SpeechTranscriber.ReportingOption>`.)
    static let reportingOptions: Set<SpeechTranscriber.ReportingOption> =
        SpeechTranscriber.Preset.progressiveTranscription.reportingOptions
            .union([.alternativeTranscriptions])

    /// Today's configuration: the progressive preset, byte-identical options.
    static func makeStandard(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    /// The composed configuration whose final results carry alternatives.
    static func make(locale: Locale) -> SpeechTranscriber {
        let preset = SpeechTranscriber.Preset.progressiveTranscription
        return SpeechTranscriber(
            locale: locale,
            transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: reportingOptions,
            attributeOptions: preset.attributeOptions)
    }
}
