# NTU ML2021 Whisper LoRA experiment

This directory is a reproducible, isolated experiment for adapting multilingual
Whisper to Mandarin-English machine-learning lectures. It does not modify the
OpenTypeless macOS application or its cloud transcription providers.

## Scope

- Base model: `openai/whisper-small` at revision
  `973afd24965f72e36ca33b3055d56a652f456b4d`
- Adaptation: rank-32 LoRA on attention query and value projections
- Training data: `ky552/ML2021_ASR_ST` at revision
  `1e121cc419e87eed7d4825400baa06f102931944`
- Validation and final evaluation: the official `dev` and `test` splits. The
  pinned dataset revision ships every `dev` file, byte-identical, inside
  `test`, so test evaluation always removes the 2,997 `dev` files and scores
  the remaining 11,919 held-out examples. The exclusion count is recorded in
  every evaluation report.
- Decoder prompt: Chinese transcription. This matches the Mandarin-dominant,
  code-switched corpus while preserving English technical terms in the output.
- Export target: a merged Hugging Face checkpoint and a quantized `whisper.cpp`
  GGML model

The repository contains no source audio, transcripts, translations, weights, or
per-sample predictions. See `NOTICE.md` before using or releasing derived
weights.

## Install

Use Python 3.11 or 3.12. The hash-locked requirements file is generated from
`pyproject.toml` and `uv.lock`.

```bash
python -m pip install --require-hashes -r requirements.txt
```

## Reproduce

First validate the pinned split structure and create an ignored local manifest.
The manifest contains only SHA-256 identifiers and transcript lengths, not text.

```bash
python -m ntuasr.prepare_dataset --output-dir artifacts/manifest
```

Run an initial 6,000-sample training experiment on a CUDA runtime:

```bash
python -m ntuasr.train \
  --output-dir artifacts/whisper-small-lora \
  --max-train-samples 6000 \
  --max-eval-samples 512 \
  --num-train-epochs 1
```

Use the full official training split only after the development protocol is
frozen:

```bash
python -m ntuasr.train \
  --output-dir artifacts/whisper-small-lora-full \
  --max-eval-samples 512 \
  --num-train-epochs 1
```

During development, evaluate only the `dev` split. A partial result is marked
ineligible for public release in its JSON report.

```bash
python -m ntuasr.evaluate \
  --base-model openai/whisper-small \
  --adapter artifacts/whisper-small-lora/adapter \
  --split dev \
  --max-samples 512 \
  --output artifacts/evaluation/fine-tuned-dev-prefix-512.json
```

After freezing the setup, evaluate the complete untouched official `test`
split. The public report includes metrics, exact revisions, package versions,
dataset fingerprint, and hashed sample identifiers. It deliberately excludes
source transcripts and predictions. Add `--private-output` only for an ignored,
local JSONL audit file.

```bash
python -m ntuasr.evaluate \
  --base-model openai/whisper-small \
  --adapter artifacts/whisper-small-lora-full/adapter \
  --split test \
  --output artifacts/evaluation/fine-tuned-test-full.json \
  --private-output artifacts/private/fine-tuned-test-full.jsonl
```

For a baseline report, omit `--adapter` and use a different output path.

## Colab

Open [`colab/Whisper_LoRA_NTU_ML2021.ipynb`](colab/Whisper_LoRA_NTU_ML2021.ipynb)
in Google Colab, choose a GPU runtime, set the exact Git commit containing this
directory, and run its cells in order. The notebook checks out that commit and
fixed revisions of OpenAI Whisper and `whisper.cpp`; no API key is required.

The first run trains 6,000 samples and evaluates `dev` only. The notebook will
not evaluate `test` unless `RUN_FINAL_TEST` is deliberately enabled after the
development choices are frozen.

## Text normalization and safety limits

The source labels use Traditional Chinese and often contain spaces between
individual Han characters. `ntuasr.normalization.normalize_transcript` removes
those intra-Han spaces, converts Traditional Chinese to Simplified Chinese, and
preserves English technical tokens. The same normalization is applied before
CER and Mandarin-English mixed error rate (MER) are calculated.

Every train and evaluation example is checked for the expected split structure,
duplicate or overlapping source IDs, 16 kHz mono audio, finite samples, a
60-second audio limit, and a 1,024-character transcript limit. Metrics use
linear memory and reject overlong token sequences.

## Local Apple Silicon use

This experiment exports multilingual `Whisper-small`, not an English-only
checkpoint. `whisper.cpp` documents the unquantized small model as 466 MiB on
disk and roughly 852 MB of runtime memory; a Q5 export is smaller. A Mac mini
with 24 GB unified memory can run it comfortably. Measure its actual real-time
factor on the target machine:

```bash
bash scripts/benchmark_local.sh \
  /path/to/whisper-cli \
  /path/to/ggml-model-q5_0.bin \
  /path/to/representative-zh-en.wav
```

The script forces the Chinese decoder prompt, matching training, and prints the
real-time factor. It is also the final local load-and-transcribe verification.

## GGML export

The Colab notebook builds fixed revisions of the conversion tools, creates a
small WAV file from the official `dev` split, and validates both unquantized and
Q5 exports with `whisper-cli`. To run the same step outside Colab:

```bash
bash scripts/export_ggml.sh \
  artifacts/whisper-small-lora-full/merged \
  artifacts/ggml \
  /path/to/whisper.cpp \
  /path/to/openai-whisper \
  /path/to/whisper-cli \
  /path/to/smoke-zh-en.wav
```

## Published artifacts

- LoRA adapter: [https://huggingface.co/Creaturelove7/whisper-small-lora-ntu-ml2021](https://huggingface.co/Creaturelove7/whisper-small-lora-ntu-ml2021)
- Held-out test reports for the base and adapted models: [`reports/`](reports/)

The release ships only weight deltas and aggregate metrics. The underlying
lecture audio remains the work of the course authors; takedown requests from
rights holders are honored (see the model card's data-provenance section).

## Publishing gate

Before publishing any further artifact (a merged checkpoint or GGML file),
confirm all of the following:

1. The data-rights gate in `NOTICE.md` has been independently cleared with
   original-owner evidence, not only the third-party dataset card.
2. The release includes the pinned dataset and base-model revisions, source
   URLs, notices, exact training command, and hash-locked dependency files.
3. A full, untouched official `test` report compares the base and adapted
   models, and both reports are eligible for public release.
4. The model card states the lecture-domain and Taiwan-accent limitations.
5. The release includes a measured Apple Silicon real-time factor and the
   successful GGML load-and-transcribe verification.
6. No source transcript, translation, audio, or per-sample prediction is
   redistributed without confirmed permission.
