"""Fine-tune multilingual Whisper-small with LoRA on the official train split."""

from __future__ import annotations

import argparse
import importlib.metadata
import json
import random
import subprocess
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np
import torch
from datasets import Audio, load_dataset
from peft import LoraConfig, get_peft_model
from transformers import (
    Seq2SeqTrainer,
    Seq2SeqTrainingArguments,
    WhisperForConditionalGeneration,
    WhisperProcessor,
)

from ntuasr.constants import (
    BASE_MODEL_ID,
    BASE_MODEL_REVISION,
    DATASET_ID,
    DATASET_REVISION,
    PRIMARY_LANGUAGE,
    TRANSCRIPTION_TASK,
)
from ntuasr.data_validation import validate_decoded_example, validate_splits
from ntuasr.whisper_configuration import configure_chinese_transcription


@dataclass(frozen=True)
class ExperimentConfig:
    base_model: str
    base_model_revision: str
    dataset: str
    dataset_revision: str
    max_train_samples: int | None
    max_eval_samples: int | None
    num_train_epochs: float
    learning_rate: float
    lora_rank: int
    seed: int
    repository_revision: str | None
    dataset_fingerprints: dict[str, str]
    package_versions: dict[str, str]
    prompt_language: str
    prompt_task: str


@dataclass
class DataCollatorSpeechSeq2SeqWithPadding:
    processor: WhisperProcessor
    decoder_start_token_id: int

    def __call__(self, features):
        input_features = [{"input_features": feature["input_features"]} for feature in features]
        batch = self.processor.feature_extractor.pad(input_features, return_tensors="pt")

        label_features = [{"input_ids": feature["labels"]} for feature in features]
        labels_batch = self.processor.tokenizer.pad(label_features, return_tensors="pt")
        labels = labels_batch["input_ids"].masked_fill(labels_batch.attention_mask.ne(1), -100)

        if (labels[:, 0] == self.decoder_start_token_id).all().cpu().item():
            labels = labels[:, 1:]
        batch["labels"] = labels
        return batch


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--base-model", default=BASE_MODEL_ID)
    parser.add_argument("--base-model-revision", default=BASE_MODEL_REVISION)
    parser.add_argument("--max-train-samples", type=int, default=None)
    parser.add_argument("--max-eval-samples", type=int, default=512)
    parser.add_argument("--num-train-epochs", type=float, default=1.0)
    parser.add_argument("--learning-rate", type=float, default=1e-4)
    parser.add_argument("--lora-rank", type=int, default=32)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--resume-from-checkpoint", type=Path, default=None)
    parser.add_argument("--eval-steps", type=int, default=250)
    return parser.parse_args()


def set_seed(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)


def limit_dataset(dataset, maximum: int | None, seed: int):
    if maximum is None or maximum >= len(dataset):
        return dataset
    return dataset.shuffle(seed=seed).select(range(maximum))


def prepare_dataset(dataset, processor: WhisperProcessor):
    dataset = dataset.cast_column("audio", Audio(sampling_rate=16_000))

    def transform(example):
        audio = example["audio"]
        text = validate_decoded_example(example, "training example")
        features = processor.feature_extractor(
            audio["array"], sampling_rate=audio["sampling_rate"]
        ).input_features[0]
        labels = processor.tokenizer(text).input_ids
        return {"input_features": features, "labels": labels}

    return dataset.map(transform, remove_columns=dataset.column_names)


def package_versions() -> dict[str, str]:
    packages = ("accelerate", "datasets", "librosa", "peft", "soundfile", "torch", "transformers")
    return {package: importlib.metadata.version(package) for package in packages}


def repository_revision() -> str | None:
    """Return the source revision when the experiment runs inside a Git checkout."""
    result = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def main() -> None:
    arguments = parse_arguments()
    if arguments.max_train_samples is not None and arguments.max_train_samples <= 0:
        raise ValueError("max_train_samples must be positive")
    if arguments.max_eval_samples is not None and arguments.max_eval_samples <= 0:
        raise ValueError("max_eval_samples must be positive")

    set_seed(arguments.seed)
    arguments.output_dir.mkdir(parents=True, exist_ok=True)
    processor = WhisperProcessor.from_pretrained(
        arguments.base_model,
        revision=arguments.base_model_revision,
        language=PRIMARY_LANGUAGE,
        task=TRANSCRIPTION_TASK,
    )
    raw_dataset = load_dataset(DATASET_ID, revision=DATASET_REVISION)
    validate_splits(raw_dataset)

    train_raw = limit_dataset(raw_dataset["train"], arguments.max_train_samples, arguments.seed)
    eval_raw = limit_dataset(raw_dataset["dev"], arguments.max_eval_samples, arguments.seed)
    train_dataset = prepare_dataset(train_raw, processor)
    eval_dataset = prepare_dataset(eval_raw, processor)

    base_model = WhisperForConditionalGeneration.from_pretrained(
        arguments.base_model,
        revision=arguments.base_model_revision,
    )
    base_model.config.use_cache = False
    configure_chinese_transcription(base_model, processor)
    lora_config = LoraConfig(
        r=arguments.lora_rank,
        lora_alpha=arguments.lora_rank * 2,
        target_modules=["q_proj", "v_proj"],
        lora_dropout=0.05,
        bias="none",
    )
    model = get_peft_model(base_model, lora_config)
    model.print_trainable_parameters()

    training_arguments = Seq2SeqTrainingArguments(
        output_dir=str(arguments.output_dir / "checkpoints"),
        per_device_train_batch_size=1,
        per_device_eval_batch_size=1,
        gradient_accumulation_steps=16,
        learning_rate=arguments.learning_rate,
        num_train_epochs=arguments.num_train_epochs,
        fp16=torch.cuda.is_available(),
        logging_steps=25,
        eval_strategy="steps",
        eval_steps=arguments.eval_steps,
        save_strategy="steps",
        save_steps=arguments.eval_steps,
        save_total_limit=2,
        load_best_model_at_end=True,
        metric_for_best_model="eval_loss",
        greater_is_better=False,
        report_to=[],
        remove_unused_columns=False,
        dataloader_num_workers=2,
        optim="adamw_torch",
        seed=arguments.seed,
    )
    collator = DataCollatorSpeechSeq2SeqWithPadding(
        processor=processor,
        decoder_start_token_id=base_model.config.decoder_start_token_id,
    )
    trainer = Seq2SeqTrainer(
        model=model,
        args=training_arguments,
        train_dataset=train_dataset,
        eval_dataset=eval_dataset,
        data_collator=collator,
        processing_class=processor.feature_extractor,
    )
    trainer.train(
        resume_from_checkpoint=str(arguments.resume_from_checkpoint)
        if arguments.resume_from_checkpoint
        else None
    )

    adapter_dir = arguments.output_dir / "adapter"
    trainer.save_model(str(adapter_dir))
    processor.save_pretrained(adapter_dir)

    merged_dir = arguments.output_dir / "merged"
    merged_model = trainer.model.merge_and_unload()
    merged_model.config.use_cache = True
    configure_chinese_transcription(merged_model, processor)
    merged_model.save_pretrained(merged_dir, safe_serialization=True)
    processor.save_pretrained(merged_dir)

    config = ExperimentConfig(
        base_model=arguments.base_model,
        base_model_revision=arguments.base_model_revision,
        dataset=DATASET_ID,
        dataset_revision=DATASET_REVISION,
        max_train_samples=arguments.max_train_samples,
        max_eval_samples=arguments.max_eval_samples,
        num_train_epochs=arguments.num_train_epochs,
        learning_rate=arguments.learning_rate,
        lora_rank=arguments.lora_rank,
        seed=arguments.seed,
        repository_revision=repository_revision(),
        dataset_fingerprints={
            split: raw_dataset[split]._fingerprint for split in sorted(raw_dataset.keys())
        },
        package_versions=package_versions(),
        prompt_language=PRIMARY_LANGUAGE,
        prompt_task=TRANSCRIPTION_TASK,
    )
    (arguments.output_dir / "experiment.json").write_text(
        json.dumps(asdict(config), indent=2) + "\n", encoding="utf-8"
    )
    print(f"Saved LoRA adapter to {adapter_dir}")
    print(f"Saved merged model to {merged_dir}")


if __name__ == "__main__":
    main()
