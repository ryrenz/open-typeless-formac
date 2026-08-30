"""Validate immutable dataset metadata and decoded examples before processing."""

from __future__ import annotations

import math
from collections.abc import Mapping

import numpy as np

from ntuasr.constants import (
    EXPECTED_SPLITS,
    MAX_AUDIO_SAMPLES,
    MAX_TRANSCRIPT_CHARACTERS,
    SAMPLE_RATE,
)
from ntuasr.normalization import normalize_transcript


def validate_splits(dataset) -> None:
    """Reject missing, unexpected, duplicate, or overlapping source identifiers."""
    received_splits = set(dataset.keys())
    if received_splits != EXPECTED_SPLITS:
        raise ValueError(f"Expected splits {EXPECTED_SPLITS}, received {received_splits}")

    split_files: dict[str, set[str]] = {}
    for split in sorted(EXPECTED_SPLITS):
        required_columns = {"file", "audio", "transcription"}
        received_columns = set(dataset[split].column_names)
        missing_columns = required_columns - received_columns
        if missing_columns:
            raise ValueError(f"{split} is missing required columns: {sorted(missing_columns)}")
        source_files = dataset[split]["file"]
        if not all(isinstance(source_file, str) and source_file for source_file in source_files):
            raise ValueError(f"{split} contains an invalid source file identifier")
        if len(source_files) != len(set(source_files)):
            raise ValueError(f"{split} contains duplicate source file identifiers")
        split_files[split] = set(source_files)

    for left, right in (("train", "dev"), ("train", "test"), ("dev", "test")):
        overlap = split_files[left] & split_files[right]
        if overlap:
            raise ValueError(f"Official splits overlap: {left}/{right} has {len(overlap)} files")


def validate_decoded_example(example: Mapping[str, object], context: str) -> str:
    """Validate one decoded row and return its normalized transcript."""
    transcription = example.get("transcription")
    normalized = normalize_transcript(transcription)
    if not normalized:
        raise ValueError(f"{context} contains an empty normalized transcript")
    if len(normalized) > MAX_TRANSCRIPT_CHARACTERS:
        raise ValueError(
            f"{context} transcript exceeds {MAX_TRANSCRIPT_CHARACTERS} characters"
        )

    audio = example.get("audio")
    if not isinstance(audio, Mapping):
        raise ValueError(f"{context} does not contain decoded audio metadata")
    sample_rate = audio.get("sampling_rate")
    values = audio.get("array")
    if sample_rate != SAMPLE_RATE:
        raise ValueError(f"{context} has sample rate {sample_rate}, expected {SAMPLE_RATE}")
    if not isinstance(values, np.ndarray) or values.ndim != 1:
        raise ValueError(f"{context} audio must be a one-dimensional NumPy array")
    if not 0 < len(values) <= MAX_AUDIO_SAMPLES:
        raise ValueError(
            f"{context} audio must contain 1..{MAX_AUDIO_SAMPLES} samples"
        )
    if not bool(np.isfinite(values).all()):
        raise ValueError(f"{context} audio contains non-finite samples")
    if not math.isfinite(float(np.max(np.abs(values)))):
        raise ValueError(f"{context} audio has an invalid amplitude")
    return normalized
