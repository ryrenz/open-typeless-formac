import unittest

from ntuasr.whisper_configuration import configure_chinese_transcription


class FakeConfig:
    forced_decoder_ids = None


class FakeModel:
    def __init__(self) -> None:
        self.config = FakeConfig()
        self.generation_config = FakeConfig()


class FakeProcessor:
    def get_decoder_prompt_ids(self, *, language, task, no_timestamps):
        self.calls = (language, task, no_timestamps)
        return [(1, 50260), (2, 50359), (3, 50363)]


class WhisperConfigurationTests(unittest.TestCase):
    def test_training_and_generation_share_chinese_transcription_prompt(self) -> None:
        model = FakeModel()
        processor = FakeProcessor()

        prompt_ids = configure_chinese_transcription(model, processor)

        self.assertEqual(processor.calls, ("zh", "transcribe", True))
        self.assertEqual(model.config.forced_decoder_ids, prompt_ids)
        self.assertEqual(model.generation_config.forced_decoder_ids, prompt_ids)
        self.assertEqual(model.generation_config.language, "zh")
        self.assertEqual(model.generation_config.task, "transcribe")
