import unittest

import numpy as np

from ntuasr.data_validation import validate_decoded_example, validate_splits


class DataValidationTests(unittest.TestCase):
    def test_accepts_a_bounded_finite_decoded_example(self) -> None:
        example = {
            "transcription": "\u9019 \u5802 \u8ab2 machine learning",
            "audio": {"sampling_rate": 16_000, "array": np.array([0.0, 0.25])},
        }
        self.assertEqual(validate_decoded_example(example, "test"), "\u8fd9\u5802\u8bfe machine learning")

    def test_rejects_non_finite_audio(self) -> None:
        example = {
            "transcription": "valid transcript",
            "audio": {"sampling_rate": 16_000, "array": np.array([0.0, np.nan])},
        }
        with self.assertRaisesRegex(ValueError, "non-finite"):
            validate_decoded_example(example, "test")

    def test_rejects_overlapping_splits(self) -> None:
        class Split(dict):
            column_names = ["file", "audio", "transcription"]

        dataset = {
            "train": Split(file=["a.flac"]),
            "dev": Split(file=["a.flac"]),
            "test": Split(file=["b.flac"]),
        }
        with self.assertRaisesRegex(ValueError, "overlap"):
            validate_splits(dataset)
