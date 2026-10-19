import AgentRunKit
import Foundation

public struct RescuedToolCall: Sendable, Equatable {
    public let toolName: String
    /// Normalized JSON: sorted keys, no extra whitespace.
    public let arguments: String
    /// The reply with the JSON block removed and surrounding whitespace trimmed.
    public let remainingText: String

    public init(toolName: String, arguments: String, remainingText: String) {
        self.toolName = toolName
        self.arguments = arguments
        self.remainingText = remainingText
    }
}

public enum ToolCallRescueResult: Sendable, Equatable {
    case none
    case ambiguous
    case found(RescuedToolCall)
}

/// Small models sometimes write a tool call as JSON in their reply instead of calling the tool.
/// This picks such a call up so the app can run it through the normal approval flow.
public enum ToolCallRescue {
    /// `knownTools`: tool name to its required argument keys. Tools without arguments are never rescued.
    public static func extract(from assistantText: String, knownTools: [String: Set<String>]) -> ToolCallRescueResult {
        let scalars = Array(assistantText.unicodeScalars)
        var candidates: [Candidate] = []
        var fenced: [Range<Int>] = []

        for block in fencedBlocks(in: scalars) {
            fenced.append(block.outer)
            candidates.append(contentsOf: objects(in: scalars, range: block.inner).map {
                Candidate(json: $0.json, outer: block.outer)
            })
        }
        candidates.append(contentsOf: objects(in: scalars, range: 0 ..< scalars.count, excluding: fenced))

        var accepted: [(call: Call, outer: Range<Int>)] = []
        for candidate in candidates {
            guard let dictionary = parse(scalars, candidate.json) else { continue }
            switch classify(dictionary, knownTools: knownTools) {
            case .rejected: continue
            case .ambiguous: return .ambiguous
            case let .call(call): accepted.append((call, candidate.outer))
            }
        }
        guard let first = accepted.first else { return .none }
        guard accepted.allSatisfy({ $0.call == first.call }) else { return .ambiguous }

        let removed = accepted.map { $0.outer }
        var kept = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() where !removed.contains(where: { $0.contains(index) }) {
            kept.append(scalar)
        }
        let remaining = String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
        return .found(RescuedToolCall(toolName: first.call.name, arguments: first.call.arguments, remainingText: remaining))
    }

    /// Required argument keys per tool, read from each tool's parameter schema.
    public static func knownTools(_ tools: [RegisteredTool<EmptyContext>]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for registered in tools {
            guard case let .object(_, required, _) = registered.tool.parametersSchema, !required.isEmpty else { continue }
            result[registered.tool.name] = Set(required)
        }
        return result
    }

    /// The text shown for a rescued call's result.
    public static func resultText(toolName: String, result: ToolResult) -> String {
        if result.isError { return result.content }
        switch toolName {
        case NoteToolName.save: return "メモを保存しました"
        case NoteToolName.edit: return "メモを更新しました"
        case NoteToolName.delete: return "メモを削除しました"
        case NoteToolName.search, NoteToolName.list:
            guard let data = result.content.data(using: .utf8),
                  let list = try? JSONDecoder().decode(NoteListText.self, from: data)
            else { return result.content }
            if list.notes.isEmpty { return "該当するメモがありません" }
            return list.notes.map { "- \($0.text)" }.joined(separator: "\n")
        default: return result.content
        }
    }

    // MARK: - Private

    private struct NoteListText: Decodable {
        struct Item: Decodable { let text: String }
        let notes: [Item]
    }

    private struct Call: Equatable {
        let name: String
        let arguments: String
    }

    private struct Candidate {
        let json: Range<Int>
        let outer: Range<Int>
    }

    private enum Classification {
        case rejected
        case ambiguous
        case call(Call)
    }

    private static func classify(_ dictionary: [String: Any], knownTools: [String: Set<String>]) -> Classification {
        for (nameKey, argumentsKey) in [("name", "arguments"), ("tool", "input")] {
            if let name = dictionary[nameKey] as? String, knownTools[name] != nil,
               let arguments = dictionary[argumentsKey] as? [String: Any],
               let normalized = normalize(arguments) {
                return .call(Call(name: name, arguments: normalized))
            }
        }
        guard !dictionary.isEmpty, dictionary.values.allSatisfy({ $0 is String }) else { return .rejected }
        let keys = Set(dictionary.keys)
        let matches = knownTools.filter { $0.value == keys }.map { $0.key }
        guard matches.count <= 1 else { return .ambiguous }
        guard let name = matches.first, let normalized = normalize(dictionary) else { return .rejected }
        return .call(Call(name: name, arguments: normalized))
    }

    private static func normalize(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func parse(_ scalars: [Unicode.Scalar], _ range: Range<Int>) -> [String: Any]? {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[range])
        guard let data = String(view).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Code fences: the opening line (with an optional language tag) to the closing fence.
    private static func fencedBlocks(in scalars: [Unicode.Scalar]) -> [(outer: Range<Int>, inner: Range<Int>)] {
        let fence: [Unicode.Scalar] = ["`", "`", "`"]
        func fenceIndex(from start: Int) -> Int? {
            var index = start
            while index + 3 <= scalars.count {
                if Array(scalars[index ..< index + 3]) == fence { return index }
                index += 1
            }
            return nil
        }
        var blocks: [(Range<Int>, Range<Int>)] = []
        var position = 0
        while let open = fenceIndex(from: position), let close = fenceIndex(from: open + 3) {
            var innerStart = open + 3
            while innerStart < close, scalars[innerStart] != "\n" { innerStart += 1 }
            if innerStart == close { innerStart = open + 3 }
            blocks.append((open ..< close + 3, innerStart ..< close))
            position = close + 3
        }
        return blocks
    }

    /// Outermost balanced `{ ... }` objects; braces inside JSON string literals do not count.
    private static func objects(
        in scalars: [Unicode.Scalar], range: Range<Int>, excluding excluded: [Range<Int>] = []
    ) -> [Candidate] {
        var found: [Candidate] = []
        var index = range.lowerBound
        while index < range.upperBound {
            if excluded.contains(where: { $0.contains(index) }) || scalars[index] != "{" {
                index += 1
                continue
            }
            if let end = balancedEnd(scalars, start: index, limit: range.upperBound) {
                found.append(Candidate(json: index ..< end, outer: index ..< end))
                index = end
            } else {
                index += 1
            }
        }
        return found
    }

    private static func balancedEnd(_ scalars: [Unicode.Scalar], start: Int, limit: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < limit {
            let scalar = scalars[index]
            if inString {
                if escaped { escaped = false } else if scalar == "\\" { escaped = true } else if scalar == "\"" { inString = false }
            } else if scalar == "\"" {
                inString = true
            } else if scalar == "{" {
                depth += 1
            } else if scalar == "}" {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
            index += 1
        }
        return nil
    }
}
