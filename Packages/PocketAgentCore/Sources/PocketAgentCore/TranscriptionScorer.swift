import Foundation

/// Character Error Rate (CER) scorer with the same normalization rules as
/// `tools/cer.py`: Unicode NFKC, then whitespace and the same punctuation
/// set are removed, so the score measures the recognized characters
/// themselves, not spacing or punctuation choices.
public enum TranscriptionScorer {
/// Punctuation and symbols ignored by default, copied from `tools/cer.py`.
/// The long-vowel mark and iteration marks are kept: they carry meaning
/// in Japanese text.
private static let punctuation: Set<Character> = [
    "!", "\"", "#", "$", "%", "&", "'", "(",
    ")", "*", "+", "-", "/", "<", "=", ">",
    "?", "@", "[", "\\", "]", "^", "_", "`",
    "{", "|", "}", "~", "«", "»", "—", "‘",
    "’", "“", "”", "„", "‥", "…", "、", "。",
    "〈", "〉", "《", "》", "「", "」", "『", "』",
    "【", "】", "・", "！", "（", "）", "，", "．",
    "：", "；", "？", "［", "］", "｛", "｝",
]

/// Normalizes text the way `tools/cer.py` does: NFKC, then remove
/// whitespace and the punctuation set above.
public static func normalize(_ text: String) -> String {
let nfkc = text.precomposedStringWithCompatibilityMapping
var result = ""
result.reserveCapacity(nfkc.count)
for character in nfkc {
if character.isWhitespace {
continue
}
if punctuation.contains(character) {
continue
}
result.append(character)
}
return result
}

/// Levenshtein distance between two Character sequences.
public static func editDistance(_ a: String, _ b: String) -> Int {
let aCharacters = Array(a)
let bCharacters = Array(b)
if aCharacters == bCharacters {
return 0
}
if aCharacters.isEmpty {
return bCharacters.count
}
if bCharacters.isEmpty {
return aCharacters.count
}
var previous = Array(0...bCharacters.count)
for (i, aCharacter) in aCharacters.enumerated() {
var current = [i + 1]
for (j, bCharacter) in bCharacters.enumerated() {
let substitutionCost = aCharacter == bCharacter ? 0 : 1
current.append(min(
previous[j + 1] + 1,
current[j] + 1,
previous[j] + substitutionCost
))
}
previous = current
}
return previous[bCharacters.count]
}

/// CER between a reference and a hypothesis, or `nil` when the
/// normalized reference is empty (no score instead of a fake zero).
public static func cer(reference: String, hypothesis: String) -> Double? {
let normalizedReference = normalize(reference)
guard !normalizedReference.isEmpty else {
return nil
}
let normalizedHypothesis = normalize(hypothesis)
return Double(editDistance(normalizedReference, normalizedHypothesis))
/ Double(normalizedReference.count)
}
}

/// The three fixed passages for the one-button transcription accuracy check,
/// taken verbatim from `docs/verification/2026-11-03-transcription-accuracy-baseline.md`.
public enum TranscriptionCheckPassage: String, CaseIterable, Sendable {
case readingAloud
case monologueMemo
case meetingTechnical

public var label: String {
switch self {
case .readingAloud:
return "A 読み上げ文"
case .monologueMemo:
return "B 独話メモ"
case .meetingTechnical:
return "C 会議・専門用語"
}
}

public var text: String {
switch self {
case .readingAloud:
return "来月から、新しい半導体工場の建設が始まります。投資額は約三千億円で、二千二十八年の稼働を目指しています。完成すれば、国内で千二百人の雇用が生まれる見込みです。"
case .monologueMemo:
return "明日の午前十時に、田中さんと打ち合わせがあります。先方から資料がまだ届いていないので、今日の夕方までに確認の連絡を入れます。帰りに、牛乳と卵と洗剤を買って帰ります。"
case .meetingTechnical:
return "本日の議題は、露光装置の納期と、歩留まりの改善についてです。先週の測定では、線幅のばらつきが一部で規格を超えていました。原因の切り分けを来週までに行い、対策を報告してください。"
}
}
}
