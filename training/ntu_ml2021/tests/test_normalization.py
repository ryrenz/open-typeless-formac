import unittest

from ntuasr.normalization import normalize_transcript


class TranscriptNormalizationTests(unittest.TestCase):
    def test_removes_intra_han_spaces_and_converts_to_simplified(self) -> None:
        self.assertEqual(
            normalize_transcript("\u9019 \u5802 \u8ab2 \u662f machine learning ML"),
            "\u8fd9\u5802\u8bfe\u662f machine learning ML",
        )

    def test_preserves_non_han_word_boundaries(self) -> None:
        self.assertEqual(
            normalize_transcript("OpenTypeless   uses  Groq"),
            "OpenTypeless uses Groq",
        )

    def test_rejects_non_string_input(self) -> None:
        with self.assertRaises(TypeError):
            normalize_transcript(None)  # type: ignore[arg-type]
