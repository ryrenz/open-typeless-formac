"""Dependency-free CER and mixed Mandarin-English error-rate utilities."""

from __future__ import annotations

import re
import unicodedata
from dataclasses import asdict, dataclass
from typing import Sequence

from ntuasr.constants import MAX_METRIC_TOKENS
from ntuasr.normalization import normalize_transcript


_MIXED_TOKENS = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]|[a-z0-9]+")


@dataclass(frozen=True)
class ErrorCounts:
    substitutions: int
    deletions: int
    insertions: int
    reference_length: int

    @property
    def errors(self) -> int:
        return self.substitutions + self.deletions + self.insertions

    @property
    def rate(self) -> float:
        if self.reference_length == 0:
            return 0.0 if self.errors == 0 else 1.0
        return self.errors / self.reference_length

    def to_dict(self) -> dict[str, int | float]:
        return {**asdict(self), "errors": self.errors, "rate": self.rate}


def cer_tokens(text: str) -> list[str]:
    """Return punctuation-insensitive Unicode characters for CER."""
    normalized = normalize_transcript(text)
    return [
        character
        for character in normalized
        if not character.isspace() and not unicodedata.category(character).startswith("P")
    ]


def mixed_tokens(text: str) -> list[str]:
    """Tokenize Han characters and contiguous Latin-number words for MER."""
    normalized = normalize_transcript(text).lower()
    return _MIXED_TOKENS.findall(normalized)


def error_counts(reference: Sequence[str], hypothesis: Sequence[str]) -> ErrorCounts:
    """Compute minimum-edit substitutions, deletions, and insertions."""
    if len(reference) > MAX_METRIC_TOKENS:
        raise ValueError(f"Metrics are limited to {MAX_METRIC_TOKENS} reference tokens")
    # A hallucinating model may repeat itself far past the reference length.
    # Score the bounded prefix exactly and charge every truncated token as an
    # insertion, keeping memory bounded without crashing the evaluation.
    overflow_insertions = max(0, len(hypothesis) - MAX_METRIC_TOKENS)
    hypothesis = hypothesis[:MAX_METRIC_TOKENS]

    previous = [(column, 0, 0, column) for column in range(len(hypothesis) + 1)]
    for row, reference_token in enumerate(reference, start=1):
        current = [(row, 0, row, 0)]
        for column, hypothesis_token in enumerate(hypothesis, start=1):
            if reference_token == hypothesis_token:
                current.append(previous[column - 1])
                continue

            diagonal = previous[column - 1]
            substitute = (diagonal[0] + 1, diagonal[1] + 1, diagonal[2], diagonal[3])
            deletion = previous[column]
            delete = (deletion[0] + 1, deletion[1], deletion[2] + 1, deletion[3])
            insertion = current[column - 1]
            insert = (insertion[0] + 1, insertion[1], insertion[2], insertion[3] + 1)
            current.append(min(substitute, delete, insert, key=lambda item: item[0]))
        previous = current

    _, substitutions, deletions, insertions = previous[-1]
    return ErrorCounts(
        substitutions, deletions, insertions + overflow_insertions, len(reference)
    )


def cer(reference: str, hypothesis: str) -> ErrorCounts:
    """Calculate character error rate after transcript normalization."""
    return error_counts(cer_tokens(reference), cer_tokens(hypothesis))


def mer(reference: str, hypothesis: str) -> ErrorCounts:
    """Calculate mixed error rate with Han characters and English words as tokens."""
    return error_counts(mixed_tokens(reference), mixed_tokens(hypothesis))


def aggregate(counts: Sequence[ErrorCounts]) -> ErrorCounts:
    """Aggregate corpus-level counts before calculating an error rate."""
    return ErrorCounts(
        substitutions=sum(item.substitutions for item in counts),
        deletions=sum(item.deletions for item in counts),
        insertions=sum(item.insertions for item in counts),
        reference_length=sum(item.reference_length for item in counts),
    )
