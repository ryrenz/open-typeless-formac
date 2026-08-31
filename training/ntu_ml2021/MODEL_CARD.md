# OpenTypeless NTU ML2021 Whisper-small LoRA

## Status

This repository contains a reproducible training recipe and no trained model
weights. Do not create a public release unless the data-rights gate in
`NOTICE.md` has been independently cleared, the trained checkpoint has been
evaluated on the complete untouched official test split, and only the aggregate
public JSON report is included in release notes. The pinned dataset revision
ships every `dev` file inside `test`, so test evaluation removes those 2,997
files and scores the 11,919 held-out examples; the report records the
exclusion.

## Base model

- Checkpoint: `openai/whisper-small`
- Revision: `973afd24965f72e36ca33b3055d56a652f456b4d`
- Type: multilingual encoder-decoder speech recognition model
- Base-model license recorded by its model card: Apache-2.0

## Adaptation

- Method: LoRA
- Trainable modules: attention `q_proj` and `v_proj`
- LoRA rank: 32
- Task: transcription only
- Language handling: fixed Chinese transcription decoder prompt, which matches
  the Mandarin-dominant code-switched training corpus while retaining English
  technical terms in the generated text
- Text convention: Simplified Chinese and original English technical tokens

## Training data

The training recipe pins `ky552/ML2021_ASR_ST` to revision
`1e121cc419e87eed7d4825400baa06f102931944`. The dataset is a Mandarin-English
machine-learning lecture corpus with pre-segmented audio, transcriptions, and
official train/dev/test splits. The dataset card records an MIT license, but it
is a third-party mirror and the original course-material rights have not yet
been independently verified. Public release of derived weights remains blocked
until that evidence is retained with the release record.

This repository does not include or redistribute any source audio, transcript,
translation, per-sample prediction, or plaintext derived data manifest.

## Evaluation

The evaluation command reports:

- CER after Traditional-to-Simplified normalization and punctuation removal;
- MER, where each Han character and each contiguous English word is one token;
- a public JSON report with test configuration, resolved revisions, package
  versions, aggregate metrics, and hashed sample identifiers.

Evaluation reports must compare the base model and adapted model on the same
untouched test split. A result on this corpus supports only the claim that the
model was evaluated on Mandarin-English machine-learning lecture speech.

## Limitations

- The source corpus is lecture speech, not conversational dictation or shell
  command input.
- The course speaker and Taiwan-accent distribution may not generalize to other
  accents, microphone conditions, or writing styles.
- Technical-term gains do not establish general ASR quality gains.
- This training recipe does not add a local-model provider to the OpenTypeless
  application.

## Release checklist

Before publishing weights, include the pinned source revision, this notice,
the applicable base-model notice, the exact training command, aggregate
evaluation JSON, successful GGML smoke-test record, and measured Apple Silicon
real-time factor. Do not publish raw source text or per-sample predictions.
