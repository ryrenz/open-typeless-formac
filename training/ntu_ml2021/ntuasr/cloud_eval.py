"""Evaluate an OpenAI-compatible cloud transcription endpoint on the dev split.

The API key is read from an environment variable and never printed. Sample
selection matches ntuasr.evaluate: the first N examples of the official split.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import time
from pathlib import Path

import requests
import soundfile
from datasets import Audio, load_dataset

from ntuasr.constants import DATASET_ID, DATASET_REVISION
from ntuasr.data_validation import validate_decoded_example, validate_splits
from ntuasr.metrics import aggregate, cer, mer
from ntuasr.normalization import normalize_transcript


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="https://api.groq.com/openai/v1")
    parser.add_argument("--model", default="whisper-large-v3")
    parser.add_argument("--api-key-env", default="GROQ_API_KEY")
    parser.add_argument("--language", default="zh")
    parser.add_argument("--split", choices=["dev"], default="dev")
    parser.add_argument("--max-samples", type=int, default=512)
    parser.add_argument("--requests-per-minute", type=float, default=18.0)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def transcribe(
    session: requests.Session,
    base_url: str,
    api_key: str,
    model: str,
    language: str,
    wav_bytes: bytes,
) -> str:
    last_failure = "no attempt made"
    for attempt in range(6):
        try:
            response = session.post(
                f"{base_url}/audio/transcriptions",
                headers={"Authorization": f"Bearer {api_key}"},
                files={"file": ("sample.wav", wav_bytes, "audio/wav")},
                data={"model": model, "language": language, "response_format": "json"},
                timeout=120,
            )
        except requests.exceptions.RequestException as error:
            last_failure = type(error).__name__
            time.sleep(min(60, 5 * 2**attempt))
            continue
        if response.status_code == 429 or response.status_code >= 500:
            last_failure = f"HTTP {response.status_code}"
            time.sleep(min(60, 5 * 2**attempt))
            continue
        response.raise_for_status()
        return response.json()["text"]
    raise RuntimeError(f"Endpoint kept failing after retries: {last_failure}")


def main() -> None:
    arguments = parse_arguments()
    api_key = os.environ.get(arguments.api_key_env)
    if not api_key:
        raise SystemExit(f"Set {arguments.api_key_env} in the environment first")

    raw_dataset = load_dataset(DATASET_ID, revision=DATASET_REVISION)
    validate_splits(raw_dataset)
    dataset = raw_dataset[arguments.split]
    dataset = dataset.select(range(min(arguments.max_samples, len(dataset))))
    dataset = dataset.cast_column("audio", Audio(sampling_rate=16_000))

    interval = 60.0 / arguments.requests_per_minute
    session = requests.Session()
    cer_counts = []
    mer_counts = []
    started = time.monotonic()
    for index in range(len(dataset)):
        example = dataset[index]
        reference = validate_decoded_example(example, f"{arguments.split} cloud example")
        buffer = io.BytesIO()
        soundfile.write(
            buffer, example["audio"]["array"], example["audio"]["sampling_rate"],
            format="WAV",
        )
        next_slot = started + index * interval
        delay = next_slot - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        prediction = normalize_transcript(
            transcribe(
                session,
                arguments.base_url,
                api_key,
                arguments.model,
                arguments.language,
                buffer.getvalue(),
            )
        )
        cer_counts.append(cer(reference, prediction))
        mer_counts.append(mer(reference, prediction))
        if (index + 1) % 25 == 0 or index + 1 == len(dataset):
            print(f"Transcribed {index + 1}/{len(dataset)} examples", flush=True)

    report = {
        "dataset_id": DATASET_ID,
        "dataset_revision": DATASET_REVISION,
        "split": arguments.split,
        "samples": len(cer_counts),
        "sample_selection": {
            "strategy": "official_split_prefix",
            "max_samples": arguments.max_samples,
            "eligible_for_public_release": False,
        },
        "endpoint": arguments.base_url,
        "model": arguments.model,
        "language": arguments.language,
        "cer": aggregate(cer_counts).to_dict(),
        "mer": aggregate(mer_counts).to_dict(),
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(json.dumps({key: report[key] for key in ("model", "samples", "cer", "mer")}, indent=2))


if __name__ == "__main__":
    main()
