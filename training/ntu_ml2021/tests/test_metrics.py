import unittest

from ntuasr.constants import MAX_METRIC_TOKENS
from ntuasr.metrics import cer, mer


class MetricTests(unittest.TestCase):
    def test_cer_uses_simplified_text(self) -> None:
        result = cer("\u9019\u5802\u8ab2", "\u8fd9\u5802\u8bfe")
        self.assertEqual(result.errors, 0)
        self.assertEqual(result.rate, 0.0)

    def test_mer_accepts_case_insensitive_english_tokens(self) -> None:
        result = mer("\u8fd9\u5802\u8bfe\u662f machine learning", "\u8fd9\u5802\u8bfe\u662f Machine Learning")
        self.assertEqual(result.errors, 0)

    def test_mer_counts_english_token_substitution(self) -> None:
        result = mer("\u4f7f\u7528 whisper small", "\u4f7f\u7528 whisper medium")
        self.assertEqual(result.substitutions, 1)
        self.assertEqual(result.deletions, 0)
        self.assertEqual(result.insertions, 0)

    def test_mer_counts_insertions_and_deletions(self) -> None:
        result = mer("\u4f7f\u7528 whisper", "\u4f7f\u7528 local whisper model")
        self.assertEqual(result.substitutions, 0)
        self.assertEqual(result.deletions, 0)
        self.assertEqual(result.insertions, 2)

    def test_metrics_reject_overlong_token_sequences(self) -> None:
        text = "a " * (MAX_METRIC_TOKENS + 1)
        with self.assertRaisesRegex(ValueError, "limited"):
            mer(text, text)
