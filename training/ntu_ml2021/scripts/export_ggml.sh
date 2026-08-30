#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
  echo "Usage: $0 <merged-model-dir> <output-dir> <whisper-cpp-dir> <openai-whisper-dir> <whisper-cli-path> <smoke-audio-path>" >&2
  exit 64
fi

merged_model_dir=$1
output_dir=$2
whisper_cpp_dir=$3
openai_whisper_dir=$4
whisper_cli=$5
smoke_audio_path=$6

converter="$whisper_cpp_dir/models/convert-h5-to-ggml.py"
quantizer="$whisper_cpp_dir/build/bin/quantize"

for required_path in "$merged_model_dir" "$whisper_cpp_dir" "$openai_whisper_dir" "$converter" "$quantizer" "$whisper_cli" "$smoke_audio_path"; do
  if [[ ! -e "$required_path" ]]; then
    echo "Required path does not exist: $required_path" >&2
    exit 66
  fi
done

mkdir -p "$output_dir"
python3 "$converter" "$merged_model_dir" "$openai_whisper_dir" "$output_dir"
"$quantizer" "$output_dir/ggml-model.bin" "$output_dir/ggml-model-q5_0.bin" q5_0

for model_path in "$output_dir/ggml-model.bin" "$output_dir/ggml-model-q5_0.bin"; do
  if [[ ! -s "$model_path" ]]; then
    echo "Model export is empty or missing: $model_path" >&2
    exit 65
  fi
  "$whisper_cli" -m "$model_path" -f "$smoke_audio_path" -l zh -nt >/dev/null
done

echo "Created $output_dir/ggml-model.bin"
echo "Created $output_dir/ggml-model-q5_0.bin"
echo "Verified both exports with whisper-cli and the provided smoke audio"
