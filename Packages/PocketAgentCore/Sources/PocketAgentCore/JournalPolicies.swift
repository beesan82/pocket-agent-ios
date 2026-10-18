import Foundation

public enum SummaryPolicy {
    public static let autoSummarizeThreshold = 200

    /// Long entries are summarized automatically, but only when the on-device model is ready.
    public static func shouldSummarize(text: String, modelReady: Bool) -> Bool {
        modelReady && text.count >= autoSummarizeThreshold
    }
}

public enum DiskSpaceRule {
    /// Free space needed before downloading a model of `modelBytes`.
    public static func requiredBytes(modelBytes: Int64) -> Int64 {
        0 // RED stub
    }

    /// Needs 1.5x the model size free (integer arithmetic).
    public static func canDownload(modelBytes: Int64, freeBytes: Int64) -> Bool {
        freeBytes >= modelBytes + modelBytes / 2
    }
}
