import Foundation

public enum SummaryPolicy {
    public static let autoSummarizeThreshold = 200

    public static func shouldSummarize(text: String, modelReady: Bool) -> Bool {
        false
    }
}

public enum DiskSpaceRule {
    public static func canDownload(modelBytes: Int64, freeBytes: Int64) -> Bool {
        false
    }
}
