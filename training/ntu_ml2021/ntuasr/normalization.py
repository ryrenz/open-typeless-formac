"""Transcript normalization shared by data preparation and evaluation."""

from __future__ import annotations

import re

from opencc import OpenCC


_HAN = r"\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff"
_INTRA_HAN_SPACE = re.compile(rf"(?<=[{_HAN}])\s+(?=[{_HAN}])")
_WHITESPACE = re.compile(r"\s+")
_SIMPLIFIER = OpenCC("t2s")


def normalize_transcript(text: str) -> str:
    """Normalize a source transcript while retaining English technical tokens."""
    if not isinstance(text, str):
        raise TypeError("text must be a string")

    text = _INTRA_HAN_SPACE.sub("", text)
    text = _SIMPLIFIER.convert(text)
    return _WHITESPACE.sub(" ", text).strip()

