#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <whisper-cli-path> <ggml-model-path> <audio-path>" >&2
  exit 64
fi

whisper_cli=$1
model_path=$2
audio_path=$3

for required_path in "$whisper_cli" "$model_path" "$audio_path"; do
  if [[ ! -e "$required_path" ]]; then
    echo "Required path does not exist: $required_path" >&2
    exit 66
  fi
done

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "ffprobe is required to calculate real-time factor." >&2
  exit 69
fi

duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$audio_path")
if ! python3 - "$duration" <<'PY'
import math
import sys

duration = float(sys.argv[1])
raise SystemExit(0 if math.isfinite(duration) and duration > 0 else 1)
PY
then
  echo "Audio duration must be a positive finite number." >&2
  exit 65
fi
started=$(python3 -c 'import time; print(time.perf_counter())')
"$whisper_cli" -m "$model_path" -f "$audio_path" -l zh -nt
finished=$(python3 -c 'import time; print(time.perf_counter())')

python3 - "$started" "$finished" "$duration" <<'PY'
import sys

started, finished, duration = map(float, sys.argv[1:])
elapsed = finished - started
print(f"elapsed_seconds={elapsed:.3f}")
print(f"audio_seconds={duration:.3f}")
print(f"rtf={elapsed / duration:.4f}")
PY
