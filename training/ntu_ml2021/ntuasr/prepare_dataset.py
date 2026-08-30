"""Create a local, normalized provenance manifest without redistributing audio."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from datasets import load_dataset

from ntuasr.constants import DATASET_ID, DATASET_REVISION
from ntuasr.data_validation import validate_splits
from ntuasr.normalization import normalize_transcript


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        required=True,
        help="Ignored local directory for provenance manifests.",
    )
    return parser.parse_args()


def write_split_manifest(dataset, split: str, output_dir: Path) -> dict[str, int]:
    metadata = dataset[split].select_columns(["file", "transcription"])
    output_path = output_dir / f"{split}.jsonl"
    with output_path.open("w", encoding="utf-8") as handle:
        for source_file, transcription in zip(metadata["file"], metadata["transcription"]):
            normalized = normalize_transcript(transcription)
            if not normalized:
                raise ValueError(f"{split} contains an empty normalized transcript")
            handle.write(
                json.dumps(
                    {
                        "source_file_sha256": hashlib.sha256(
                            source_file.encode("utf-8")
                        ).hexdigest(),
                        "transcript_sha256": hashlib.sha256(
                            normalized.encode("utf-8")
                        ).hexdigest(),
                        "normalized_character_count": len(normalized),
                    },
                    ensure_ascii=False,
                )
            )
            handle.write("\n")

    return {"examples": len(metadata), "unique_source_files": len(set(metadata["file"]))}


def main() -> None:
    arguments = parse_arguments()
    arguments.output_dir.mkdir(parents=True, exist_ok=True)

    dataset = load_dataset(DATASET_ID, revision=DATASET_REVISION)
    validate_splits(dataset)

    summary = {
        "dataset_id": DATASET_ID,
        "dataset_revision": DATASET_REVISION,
        "splits": {
            split: write_split_manifest(dataset, split, arguments.output_dir)
            for split in ("train", "dev", "test")
        },
    }
    (arguments.output_dir / "manifest.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
