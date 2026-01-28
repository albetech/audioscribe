#!/usr/bin/env bash
set -euo pipefail

MODEL="${MODEL:-large-v3}"
FORMAT="${FORMAT:-txt}"
LANGUAGE="${LANGUAGE:-}"
VENV="${VENV:-/home/sasha/projects/mp3-transcribe/.venv}"
COMPUTE_TYPE="${COMPUTE_TYPE:-int8}"
BEAM_SIZE="${BEAM_SIZE:-5}"
PRINT_SEGMENTS="${PRINT_SEGMENTS:-1}"
VAD_FILTER="${VAD_FILTER:-0}"

export HF_HUB_DISABLE_PROGRESS_BARS=0

if [[ ! -x "$VENV/bin/python" ]]; then
  echo "[err] venv not found: $VENV" >&2
  exit 1
fi

shopt -s nullglob
files=( *.mp3 )
if [[ ${#files[@]} -eq 0 ]]; then
  echo "[info] mp3 files not found in current directory"
  exit 0
fi

for f in "${files[@]}"; do
  base="${f%.*}"
  if [[ -f "${base}.txt" || -f "${base}.srt" || -f "${base}.json" ]]; then
    echo "[skip] $f (output exists)"
    continue
  fi

  echo "[file] $f"
  cmd=("$VENV/bin/python" "/home/sasha/projects/mp3-transcribe/transcribe.py" "$f"
       --model "$MODEL" --format "$FORMAT" --compute-type "$COMPUTE_TYPE" --beam-size "$BEAM_SIZE")
  if [[ -n "$LANGUAGE" ]]; then
    cmd+=(--language "$LANGUAGE")
  fi
  if [[ "$PRINT_SEGMENTS" == "1" ]]; then
    cmd+=(--print-segments)
  fi
  if [[ "$VAD_FILTER" == "1" ]]; then
    cmd+=(--vad-filter)
  fi

  "${cmd[@]}"
  echo
 done
