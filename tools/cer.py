#!/usr/bin/env python3
"""Character Error Rate (CER) scorer for Japanese transcription checks.

Usage:
    python3 tools/cer.py REFERENCE_FILE HYPOTHESIS_FILE [--keep-punct] [--keep-numerals]

Both files are plain UTF-8 text. By default the text is normalized before
scoring: Unicode NFKC, then whitespace and punctuation are removed, then
numeral notations are unified (kanji numerals are converted to the plain
Arabic value, so 三千 and 3000 score the same; ADR-046), so the score
measures the recognized characters themselves, not spacing, punctuation
or numeral notation choices.

Pass --keep-punct to score the raw text (NFKC only, no numeral
conversion either). Pass --keep-numerals to keep the punctuation removal
but skip the numeral conversion, reproducing the pre-ADR-046 rules (the
old series).

CER = Levenshtein distance between the normalized strings, divided by the
number of characters in the normalized reference.
"""

import sys
import unicodedata

# Punctuation and symbols ignored by default. The long-vowel mark and
# iteration marks are kept: they carry meaning in Japanese text.
_PUNCT = set(
    "、。．，・：；！？!?「」『』（）()［］[]｛｝{}〈〉《》【】"
    "…‥„“”‘’\"'«»_-—/\\|@#$%^&*+=<>~^`"
)

# Numeral notation conversion (ADR-046). The same rules are implemented in
# TranscriptionScorer (PocketAgentCore); tools/test_cer.py and the Swift
# tests run the same cases against both.
_KANJI_DIGITS = {"一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}
_ZERO_CHARS = {"〇", "零"}
_SMALL_UNITS = {"十": 10, "百": 100, "千": 1000}
_SMALL_RANK = {1000: 3, 100: 2, 10: 1}
_LARGE_UNITS = {"万": 10 ** 4, "億": 10 ** 8, "兆": 10 ** 12}
_LARGE_RANK = {"兆": 3, "億": 2, "万": 1}
_NUMERAL_CHARS = (
    set("0123456789") | set(_KANJI_DIGITS) | _ZERO_CHARS | set(_SMALL_UNITS) | set(_LARGE_UNITS)
)


def _is_arabic(ch):
    return "0" <= ch <= "9"


def _parse_section(chars, i):
    """Parse a <10000 section of a numeral run.

    Returns (value, next_index, consumed) or None when the section does
    not follow the grammar ([number]千 [number]百 [number]十 [number],
    small units strictly descending, each at most once).
    """
    value = 0
    consumed = False
    last_small_rank = 4
    n = len(chars)
    while i < n:
        ch = chars[i]
        if ch in _LARGE_UNITS:
            break
        if ch in _ZERO_CHARS:
            return None  # zeros mixed with units are ambiguous; hands off
        num = None
        if ch in _KANJI_DIGITS:
            num = _KANJI_DIGITS[ch]
            i += 1
        elif _is_arabic(ch):
            j = i
            while j < n and _is_arabic(chars[j]):
                j += 1
            num = int("".join(chars[i:j]))
            i = j
        elif ch in _SMALL_UNITS:
            num = None  # bare unit; the unit branch below uses implicit 1
        else:
            break
        if i < n and chars[i] in _SMALL_UNITS:
            unit = _SMALL_UNITS[chars[i]]
            rank = _SMALL_RANK[unit]
            if rank >= last_small_rank:
                return None
            last_small_rank = rank
            value += (num if num is not None else 1) * unit
            consumed = True
            i += 1
            continue
        if num is None:
            break  # unreachable in practice
        # A trailing number is only valid before a large unit or at the
        # end of the run.
        if i < n and chars[i] not in _LARGE_UNITS:
            return None
        value += num
        consumed = True
        break
    return (value, i, consumed)


def _parse_run(run):
    """Return the int value of one maximal numeral run, or None to keep it."""
    chars = list(run)
    has_unit = any(c in _SMALL_UNITS or c in _LARGE_UNITS for c in chars)
    if not has_unit:
        # Digit-string reading: each character is one decimal digit.
        out = []
        for c in chars:
            if _is_arabic(c):
                out.append(c)
            elif c in _KANJI_DIGITS:
                out.append(str(_KANJI_DIGITS[c]))
            elif c in _ZERO_CHARS:
                out.append("0")
            else:
                return None
        return int("".join(out))
    if any(c in _ZERO_CHARS for c in chars):
        return None
    total = 0
    i = 0
    n = len(chars)
    last_large_rank = 4
    while True:
        section = _parse_section(chars, i)
        if section is None:
            return None
        value, i, consumed = section
        if i < n and chars[i] in _LARGE_UNITS:
            unit_char = chars[i]
            rank = _LARGE_RANK[unit_char]
            # A large unit needs a non-empty section before it, so a bare
            # 万/億/兆 (as in 万一 or 万歳) is never converted.
            if rank >= last_large_rank or not consumed:
                return None
            last_large_rank = rank
            total += value * _LARGE_UNITS[unit_char]
            i += 1
            if i >= n:
                break
            continue
        total += value
        break
    return total


def convert_numerals(text):
    out = []
    i = 0
    n = len(text)
    while i < n:
        if text[i] in _NUMERAL_CHARS:
            j = i
            while j < n and text[j] in _NUMERAL_CHARS:
                j += 1
            run = text[i:j]
            value = _parse_run(run)
            out.append(str(value) if value is not None else run)
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def normalize(text, keep_punct, keep_numerals=False):
    text = unicodedata.normalize("NFKC", text)
    if keep_punct:
        return text
    out = []
    for ch in text:
        if ch.isspace():
            continue
        if ch in _PUNCT:
            continue
        out.append(ch)
    result = "".join(out)
    if not keep_numerals:
        result = convert_numerals(result)
    return result


def levenshtein(a, b):
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, start=1):
        cur = [i]
        for j, cb in enumerate(b, start=1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[len(b)]


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    keep_punct = "--keep-punct" in argv[1:]
    keep_numerals = "--keep-numerals" in argv[1:]
    if len(args) != 2:
        print(__doc__)
        return 2
    with open(args[0], encoding="utf-8") as f:
        reference = normalize(f.read(), keep_punct, keep_numerals)
    with open(args[1], encoding="utf-8") as f:
        hypothesis = normalize(f.read(), keep_punct, keep_numerals)
    if not reference:
        print("error: reference is empty after normalization", file=sys.stderr)
        return 2
    distance = levenshtein(reference, hypothesis)
    cer = distance / len(reference) * 100
    print("reference chars : %d" % len(reference))
    print("hypothesis chars: %d" % len(hypothesis))
    print("edit distance   : %d" % distance)
    print("CER             : %.2f%%" % cer)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
