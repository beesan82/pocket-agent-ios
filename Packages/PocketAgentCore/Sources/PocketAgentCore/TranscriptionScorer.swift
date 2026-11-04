import Foundation

/// Character Error Rate (CER) scorer with the same normalization rules as
/// `tools/cer.py`: Unicode NFKC, then whitespace and the same punctuation
/// set are removed, then numeral notations are unified (kanji numerals
/// become the plain Arabic value, ADR-046), so the score measures the
/// recognized characters themselves, not spacing, punctuation or numeral
/// notation choices.
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
/// whitespace and the punctuation set above, then unify numeral
/// notations (`convertingNumerals`).
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
return convertingNumerals(result)
}

/// Kanji digit values for the numeral notation conversion (ADR-046),
/// mirrored from `tools/cer.py`. The two implementations must agree;
/// the same cases run in the Swift tests and in `tools/test_cer.py`.
private static let kanjiDigits: [Character: Int] = [
"一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
"六": 6, "七": 7, "八": 8, "九": 9,
]
private static let numeralZeroCharacters: Set<Character> = ["〇", "零"]
private static let smallUnits: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
private static let smallUnitRanks: [Int: Int] = [1000: 3, 100: 2, 10: 1]
private static let largeUnits: [Character: Int] = ["万": 10000, "億": 100000000, "兆": 1000000000000]
private static let largeUnitRanks: [Character: Int] = ["兆": 3, "億": 2, "万": 1]
private static let arabicDigits: Set<Character> = Set("0123456789")
private static let numeralCharacters: Set<Character> = Set("0123456789一二三四五六七八九〇零十百千万億兆")

/// Unifies numeral notations: every maximal run of numeral characters
/// is replaced by its plain Arabic value when it parses under the
/// shared grammar; unparseable runs are kept as written.
private static func convertingNumerals(_ text: String) -> String {
let characters = Array(text)
var result = ""
result.reserveCapacity(characters.count)
var i = 0
while i < characters.count {
if numeralCharacters.contains(characters[i]) {
var j = i
while j < characters.count && numeralCharacters.contains(characters[j]) {
j += 1
}
let run = Array(characters[i..<j])
if let value = parseNumeralRun(run) {
result += String(value)
} else {
result += String(run)
}
i = j
} else {
result.append(characters[i])
i += 1
}
}
return result
}

/// Returns the value of one maximal numeral run, mirroring `_parse_run`
/// in `tools/cer.py`, or nil to keep the run as written.
private static func parseNumeralRun(_ characters: [Character]) -> Int? {
let hasUnit = characters.contains { smallUnits[$0] != nil || largeUnits[$0] != nil }
if !hasUnit {
var digits = ""
for character in characters {
if arabicDigits.contains(character) {
digits.append(character)
} else if let digit = kanjiDigits[character] {
digits += String(digit)
} else if numeralZeroCharacters.contains(character) {
digits.append("0")
} else {
return nil
}
}
return Int(digits)
}
if characters.contains(where: { numeralZeroCharacters.contains($0) }) {
return nil
}
var total = 0
var i = 0
var lastLargeRank = 4
while true {
guard let section = parseNumeralSection(characters, from: i) else {
return nil
}
i = section.next
if i < characters.count, let unit = largeUnits[characters[i]] {
let rank = largeUnitRanks[characters[i]]!
if rank >= lastLargeRank || !section.consumed {
return nil
}
lastLargeRank = rank
let product = section.value.multipliedReportingOverflow(by: unit)
let sum = total.addingReportingOverflow(product.partialValue)
if product.overflow || sum.overflow {
return nil
}
total = sum.partialValue
i += 1
if i >= characters.count {
break
}
continue
}
total += section.value
break
}
return total
}

/// Parses one section (below 10000) of a numeral run, mirroring
/// `_parse_section` in `tools/cer.py`. Returns nil when the section
/// breaks the grammar: [number]千 [number]百 [number]十 [number], with
/// small units strictly descending, each at most once.
private static func parseNumeralSection(_ characters: [Character], from start: Int) -> (value: Int, next: Int, consumed: Bool)? {
var value = 0
var consumed = false
var lastSmallRank = 4
var i = start
while i < characters.count {
let character = characters[i]
if largeUnits[character] != nil {
break
}
if numeralZeroCharacters.contains(character) {
return nil
}
var number: Int? = nil
if let digit = kanjiDigits[character] {
number = digit
i += 1
} else if arabicDigits.contains(character) {
var j = i
var digits = ""
while j < characters.count && arabicDigits.contains(characters[j]) {
digits.append(characters[j])
j += 1
}
guard let parsed = Int(digits) else {
return nil
}
number = parsed
i = j
} else if smallUnits[character] != nil {
number = nil
} else {
break
}
if i < characters.count, let unit = smallUnits[characters[i]] {
let rank = smallUnitRanks[unit]!
if rank >= lastSmallRank {
return nil
}
lastSmallRank = rank
let product = (number ?? 1).multipliedReportingOverflow(by: unit)
if product.overflow {
return nil
}
value += product.partialValue
consumed = true
i += 1
continue
}
guard let trailing = number else {
break
}
if i < characters.count && largeUnits[characters[i]] == nil {
return nil
}
value += trailing
consumed = true
break
}
return (value, i, consumed)
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
