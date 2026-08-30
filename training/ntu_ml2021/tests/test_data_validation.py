import unittest

import numpy as np

from ntuasr.data_validation import (
    held_out_test_indices,
    validate_decoded_example,
    validate_splits,
)


class Split(dict):
    column_names = ["file", "audio", "transcription"]


def make_dataset(train, dev, test):
    return {
        "train": Split(file=train),
        "dev": Split(file=dev),
        "test": Split(file=test),
    }


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

    def test_rejects_train_overlapping_dev(self) -> None:
        dataset = make_dataset(["a.flac"], ["a.flac"], ["b.flac"])
        with self.assertRaisesRegex(ValueError, "overlap"):
            validate_splits(dataset)

    def test_accepts_dev_fully_contained_in_test(self) -> None:
        dataset = make_dataset(["a.flac"], ["d.flac"], ["d.flac", "t.flac"])
        validate_splits(dataset)

    def test_rejects_partial_dev_test_overlap(self) -> None:
        dataset = make_dataset(["a.flac"], ["d.flac", "e.flac"], ["d.flac", "t.flac"])
        with self.assertRaisesRegex(ValueError, "without dev being fully contained"):
            validate_splits(dataset)

    def test_held_out_test_excludes_dev_files(self) -> None:
        dataset = make_dataset(["a.flac"], ["d.flac"], ["d.flac", "t.flac", "u.flac"])
        self.assertEqual(held_out_test_indices(dataset), [1, 2])
