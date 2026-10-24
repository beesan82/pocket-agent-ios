import Foundation
import Observation
import PocketAgentCore

/// A single unfinished journal capture. Its id is also the id used when saving,
/// so recovery after a failed cleanup cannot create a second journal entry.
struct JournalDraft: Codable, Equatable, Identifiable {
    let id: UUID
    let source: JournalEntry.Source
    var transcript: String
    var summaryBody: String
    var summaryTitle: String
    var summarySource: String?
    var isSummaryPartial: Bool

    init(id: UUID = UUID(), source: JournalEntry.Source, transcript: String,
         summaryBody: String = "", summaryTitle: String = "", summarySource: String? = nil,
         isSummaryPartial: Bool = false) {
        self.id = id
        self.source = source
        self.transcript = transcript
        self.summaryBody = summaryBody
        self.summaryTitle = summaryTitle
        self.summarySource = summarySource
        self.isSummaryPartial = isSummaryPartial
    }
}

/// Local only. Writes are atomic; failed writes keep the in-memory draft for retry.
/// No deferred writer is left behind after discard or a successful journal save.
@MainActor
@Observable
final class JournalDraftStore {
    static let writeFailedText = "下書きを端末に保存できませんでした。この画面を閉じる前に、もう一度保存してください。"
    static let clearFailedText = "下書きを削除できませんでした。もう一度お試しください。"
    private(set) var draft: JournalDraft?
    private(set) var errorMessage: String?
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let removeItem: (URL) throws -> Void

    init(fileURL: URL = URL.applicationSupportDirectory.appending(path: "journal-draft.json"),
         removeItem: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.fileURL = fileURL
        self.removeItem = removeItem
        do {
            draft = try JSONDecoder().decode(JournalDraft.self, from: Data(contentsOf: fileURL))
        } catch {
            if !Self.isMissing(error) {
                errorMessage = "下書きを読み込めませんでした。新しく記録するには、下書きを破棄してください。"
            }
        }
    }

    func save(_ draft: JournalDraft) throws {
        self.draft = draft
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(draft)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            errorMessage = nil
        } catch {
            errorMessage = Self.writeFailedText
            throw error
        }
    }

    func clear() throws {
        do {
            try removeItem(fileURL)
        } catch {
            guard Self.isMissing(error) else {
                errorMessage = Self.clearFailedText
                throw error
            }
        }
        draft = nil
        errorMessage = nil
    }

    private static func isMissing(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
    }
}
