#!/usr/bin/env python3
"""Character Error Rate (CER) scorer for Japanese transcription checks.

Usage:
    python3 tools/cer.py REFERENCE_FILE HYPOTHESIS_FILE [--keep-punct]

Both files are plain UTF-8 text. By default the text is normalized before
scoring: Unicode NFKC, then whitespace and punctuation are removed, so the
score measures the recognized characters themselves, not spacing or
punctuation choices. Pass --keep-punct to score the raw text (NFKC only).

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


def normalize(text, keep_punct):
    text = unicodedata.normalize("NFKC", text)
    out = []
    for ch in text:
        if ch.isspace():
            continue
        if not keep_punct and ch in _PUNCT:
            continue
        out.append(ch)
    return "".join(out)


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
    if len(args) != 2:
        print(__doc__)
        return 2
    with open(args[0], encoding="utf-8") as f:
        reference = normalize(f.read(), keep_punct)
    with open(args[1], encoding="utf-8") as f:
        hypothesis = normalize(f.read(), keep_punct)
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
