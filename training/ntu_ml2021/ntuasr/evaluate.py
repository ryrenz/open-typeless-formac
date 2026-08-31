"""Evaluate a base model or adapter without publishing source transcripts."""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path

import torch
from datasets import Audio, load_dataset
from peft import PeftModel
from transformers import WhisperForConditionalGeneration, WhisperProcessor

from ntuasr.constants import (
    BASE_MODEL_ID,
    BASE_MODEL_REVISION,
    DATASET_ID,
    DATASET_REVISION,
    PRIMARY_LANGUAGE,
    TRANSCRIPTION_TASK,
)
from ntuasr.data_validation import (
    held_out_test_indices,
    validate_decoded_example,
    validate_splits,
)
from ntuasr.metrics import aggregate, cer, mer
from ntuasr.normalization import normalize_transcript
from ntuasr.whisper_configuration import configure_chinese_transcription


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-model", default=BASE_MODEL_ID)
    parser.add_argument("--base-model-revision", default=BASE_MODEL_REVISION)
    parser.add_argument("--adapter", type=Path, default=None)
    parser.add_argument("--split", choices=["train", "dev", "test"], default="test")
    parser.add_argument("--max-samples", type=int, default=None)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--private-output",
        type=Path,
        default=None,
        help="Ignored local JSONL path for per-sample references and predictions.",
    )
    return parser.parse_args()


def package_versions() -> dict[str, str]:
    packages = ("accelerate", "datasets", "librosa", "peft", "soundfile", "torch", "transformers")
    return {package: importlib.metadata.version(package) for package in packages}


def source_hash(source_file: str) -> str:
    return hashlib.sha256(source_file.encode("utf-8")).hexdigest()


def write_private_row(handle, source_file: str, reference: str, prediction: str) -> None:
    handle.write(
        json.dumps(
            {
                "source_file": source_file,
                "reference": reference,
                "prediction": prediction,
            },
            ensure_ascii=False,
        )
    )
    handle.write("\n")


def main() -> None:
    arguments = parse_arguments()
    if arguments.max_samples is not None and arguments.max_samples <= 0:
        raise ValueError("max_samples must be positive")
    if arguments.batch_size <= 0:
        raise ValueError("batch_size must be positive")

    if torch.cuda.is_available():
        device = torch.device("cuda")
    elif torch.backends.mps.is_available():
        device = torch.device("mps")
    else:
        device = torch.device("cpu")
    processor = WhisperProcessor.from_pretrained(
        arguments.adapter or arguments.base_model,
        revision=None if arguments.adapter else arguments.base_model_revision,
        language=PRIMARY_LANGUAGE,
        task=TRANSCRIPTION_TASK,
    )
    model = WhisperForConditionalGeneration.from_pretrained(
        arguments.base_model,
        revision=arguments.base_model_revision,
    )
    if arguments.adapter:
        model = PeftModel.from_pretrained(model, arguments.adapter)
    configure_chinese_transcription(model, processor)
    model.to(device)
    model.eval()

    raw_dataset = load_dataset(DATASET_ID, revision=DATASET_REVISION)
    validate_splits(raw_dataset)
    dataset = raw_dataset[arguments.split]
    excluded_dev_files = 0
    if arguments.split == "test":
        held_out = held_out_test_indices(raw_dataset)
        excluded_dev_files = len(dataset) - len(held_out)
        dataset = dataset.select(held_out)
        print(
            f"Evaluating {len(dataset)} held-out test examples "
            f"({excluded_dev_files} dev files excluded)"
        )
    if arguments.max_samples is not None:
        dataset = dataset.select(range(min(arguments.max_samples, len(dataset))))
    dataset = dataset.cast_column("audio", Audio(sampling_rate=16_000))

    cer_counts = []
    mer_counts = []
    public_sample_hashes = []
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    private_handle = None
    if arguments.private_output:
        arguments.private_output.parent.mkdir(parents=True, exist_ok=True)
        private_handle = arguments.private_output.open("w", encoding="utf-8")
    try:
        for start in range(0, len(dataset), arguments.batch_size):
            examples = [
                dataset[index]
                for index in range(start, min(start + arguments.batch_size, len(dataset)))
            ]
            references = [
                validate_decoded_example(example, f"{arguments.split} evaluation example")
                for example in examples
            ]
            inputs = processor.feature_extractor(
                [example["audio"]["array"] for example in examples],
                sampling_rate=16_000,
                return_tensors="pt",
                padding=True,
            ).input_features.to(device)
            with torch.inference_mode(), torch.autocast(
                device_type=device.type, dtype=torch.float16, enabled=device.type == "cuda"
            ):
                generated_ids = model.generate(inputs)
            predictions = processor.batch_decode(generated_ids, skip_special_tokens=True)
            for example, reference, prediction in zip(examples, references, predictions):
                normalized_prediction = normalize_transcript(prediction)
                cer_counts.append(cer(reference, normalized_prediction))
                mer_counts.append(mer(reference, normalized_prediction))
                public_sample_hashes.append(source_hash(example["file"]))
                if private_handle:
                    write_private_row(
                        private_handle,
                        example["file"],
                        reference,
                        normalized_prediction,
                    )
            print(f"Evaluated {min(start + len(examples), len(dataset))}/{len(dataset)} examples")
    finally:
        if private_handle:
            private_handle.close()

    sample_selection = (
        {"strategy": "complete_official_split", "eligible_for_public_release": True}
        if arguments.max_samples is None
        else {
            "strategy": "official_split_prefix",
            "max_samples": arguments.max_samples,
            "eligible_for_public_release": False,
        }
    )
    report = {
        "dataset_id": DATASET_ID,
        "dataset_revision": DATASET_REVISION,
        "dataset_fingerprint": raw_dataset[arguments.split]._fingerprint,
        "split": arguments.split,
        "excluded_dev_files": excluded_dev_files,
        "samples": len(public_sample_hashes),
        "sample_selection": sample_selection,
        "sample_sha256": public_sample_hashes,
        "base_model": arguments.base_model,
        "base_model_revision": arguments.base_model_revision,
        "adapter": str(arguments.adapter) if arguments.adapter else None,
        "prompt": {"language": PRIMARY_LANGUAGE, "task": TRANSCRIPTION_TASK},
        "device": str(device),
        "package_versions": package_versions(),
        "cer": aggregate(cer_counts).to_dict(),
        "mer": aggregate(mer_counts).to_dict(),
    }
    arguments.output.write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(json.dumps({key: report[key] for key in ("samples", "cer", "mer")}, indent=2))


if __name__ == "__main__":
    main()
