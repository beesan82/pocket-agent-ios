#!/usr/bin/env python3
"""Tests for tools/cer.py, focused on the numeral notation normalization.

Run with: python3 tools/test_cer.py

The conversion cases mirror TranscriptionScorerNumeralTests in
Packages/PocketAgentCore/Tests: the Swift scorer and this script must
implement the same rules (ADR-046).
"""

import unittest

from cer import levenshtein, normalize


def scored(ref, hyp):
    r = normalize(ref, keep_punct=False)
    h = normalize(hyp, keep_punct=False)
    return levenshtein(r, h) / len(r)


class NumeralConversionTests(unittest.TestCase):
    def test_kanji_numerals_convert_to_arabic_form(self):
        cases = {
            "三千": "3000",
            "二千二十八": "2028",
            "千二百": "1200",
            "一万二千": "12000",
            "十": "10",
            "二〇二八": "2028",
            "一億二千三百四十五万六千七百八十九": "123456789",
        }
        for src, want in cases.items():
            with self.subTest(src=src):
                self.assertEqual(normalize(src, keep_punct=False), want)

    def test_large_units_expand_to_plain_values(self):
        self.assertEqual(normalize("三千億", keep_punct=False), "300000000000")
        self.assertEqual(normalize("3000億", keep_punct=False), "300000000000")
        self.assertEqual(normalize("3千", keep_punct=False), "3000")

    def test_notation_only_differences_score_zero(self):
        self.assertEqual(scored("三千", "3000"), 0)
        self.assertEqual(scored("午前十時", "午前10時"), 0)
        self.assertEqual(scored("一部", "1部"), 0)

    def test_text_without_numerals_is_unchanged(self):
        self.assertEqual(normalize("露光装置の納期", keep_punct=False), "露光装置の納期")

    def test_unparseable_numerals_are_left_unchanged(self):
        for src in ("億", "万一", "三五百", "二千〇八"):
            with self.subTest(src=src):
                self.assertEqual(normalize(src, keep_punct=False), src)

    def test_keep_numerals_reproduces_the_old_rules(self):
        # Old series: the notation difference itself counts as an error.
        r = normalize("三千", keep_punct=False, keep_numerals=True)
        h = normalize("3000", keep_punct=False, keep_numerals=True)
        self.assertEqual((r, h), ("三千", "3000"))
        self.assertGreater(levenshtein(r, h), 0)


class FirstBaselineRescoreTests(unittest.TestCase):
    """The 2026-11-04 on-device hypotheses re-scored under the new rules."""

    def test_passage_a(self):
        ref = "来月から、新しい半導体工場の建設が始まります。投資額は約三千億円で、二千二十八年の稼働を目指しています。完成すれば、国内で千二百人の雇用が生まれる見込みです。"
        hyp = "来月から新しい半導体工場の建設が始まります。投資額は約3000億円で2028年の稼働を目指しています。完成すれば国内で1200人の雇用が生まれる見込み"
        self.assertAlmostEqual(scored(ref, hyp), 2 / 82, places=9)

    def test_passage_b(self):
        ref = "明日の午前十時に、田中さんと打ち合わせがあります。先方から資料がまだ届いていないので、今日の夕方までに確認の連絡を入れます。帰りに、牛乳と卵と洗剤を買って帰ります。"
        hyp = "明日の午前10時に田中さんと打ち合わせがあります。先方から資料がまだ届いていないので、今日の夕方までに確認の連絡を入れます。帰りに牛乳と卵と洗剤を買って帰ります"
        self.assertEqual(scored(ref, hyp), 0)

    def test_passage_c(self):
        ref = "本日の議題は、露光装置の納期と、歩留まりの改善についてです。先週の測定では、線幅のばらつきが一部で規格を超えていました。原因の切り分けを来週までに行い、対策を報告してください。"
        hyp = "本日の議題は路行装置の納期とぶどまりの改善についてです。先週の測定では先幅のばらつきが1部で企画を超えていました。原因の切り分けを来週までに行い、対策を報告してください"
        self.assertAlmostEqual(scored(ref, hyp), 7 / 81, places=9)


if __name__ == "__main__":
    unittest.main()
