"""Keep Whisper training labels and generation prompts aligned."""

from __future__ import annotations

from ntuasr.constants import PRIMARY_LANGUAGE, TRANSCRIPTION_TASK


def configure_chinese_transcription(model, processor) -> list[tuple[int, int]]:
    """Configure Mandarin transcription while preserving English terms in the text."""
    prompt_ids = processor.get_decoder_prompt_ids(
        language=PRIMARY_LANGUAGE,
        task=TRANSCRIPTION_TASK,
        no_timestamps=True,
    )
    model.config.forced_decoder_ids = prompt_ids
    model.generation_config.forced_decoder_ids = prompt_ids
    model.generation_config.language = PRIMARY_LANGUAGE
    model.generation_config.task = TRANSCRIPTION_TASK
    return prompt_ids
