#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: transcribe_one.sh [options] /path/to/file.mp3

options:
  --model NAME            (default: medium)
  --format txt|srt|json    (default: txt)
  --compute-type TYPE     (default: int8)
  --beam-size N           (default: 5)
  --language CODE         (default: auto)
  --diarize / --no-diarize
  --print-segments / --no-print-segments
  --vad-filter / --no-vad-filter
  --media-dir PATH        (default: /home/sasha/projects/mp3-transcribe/Media)
  --output-dir PATH       (default: MEDIA_DIR)
  --venv PATH             (default: /home/sasha/projects/mp3-transcribe/.venv)
  -h, --help              show this help
USAGE
}

VENV="/home/sasha/projects/mp3-transcribe/.venv"
MEDIA_DIR="/home/sasha/projects/mp3-transcribe/Media"
MODEL="medium"
FORMAT="txt"
COMPUTE_TYPE="int8"
BEAM_SIZE="5"
PRINT_SEGMENTS=0
VAD_FILTER=0
DIARIZE=0
DIARIZE_TEMP=0
ASR_LANGUAGE=""
OUTPUT_DIR=""
FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="$2"; shift 2;;
    --format) FORMAT="$2"; shift 2;;
    --compute-type) COMPUTE_TYPE="$2"; shift 2;;
    --beam-size) BEAM_SIZE="$2"; shift 2;;
    --language|--asr-language) ASR_LANGUAGE="$2"; shift 2;;
    --diarize) DIARIZE=1; shift;;
    --no-diarize) DIARIZE=0; shift;;
    --diarize-temp) DIARIZE_TEMP=1; shift;;
    --diarize-no-temp) DIARIZE_TEMP=0; shift;;
    --print-segments) PRINT_SEGMENTS=1; shift;;
    --no-print-segments) PRINT_SEGMENTS=0; shift;;
    --vad-filter) VAD_FILTER=1; shift;;
    --no-vad-filter) VAD_FILTER=0; shift;;
    --media-dir) MEDIA_DIR="$2"; shift 2;;
    --output-dir) OUTPUT_DIR="$2"; shift 2;;
    --venv) VENV="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    --) shift; break;;
    -*) echo "[err] unknown option: $1" >&2; usage; exit 2;;
    *) if [[ -z "$FILE" ]]; then FILE="$1"; shift; else shift; fi;;
  esac
done

if [[ -z "$FILE" ]]; then
  usage
  exit 1
fi

export HF_HUB_DISABLE_PROGRESS_BARS=0

if [[ ! -x "$VENV/bin/python" ]]; then
  echo "[err] venv not found: $VENV" >&2
  exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$MEDIA_DIR"
fi

if [[ "$FILE" != /* && ! -f "$FILE" && -f "$MEDIA_DIR/$FILE" ]]; then
  FILE="$MEDIA_DIR/$FILE"
fi

cmd=("$VENV/bin/python" "/home/sasha/projects/mp3-transcribe/transcribe.py" "$FILE"
     --model "$MODEL" --format "$FORMAT" --compute-type "$COMPUTE_TYPE" --beam-size "$BEAM_SIZE"
     --output-dir "$OUTPUT_DIR")

if [[ -n "$ASR_LANGUAGE" ]]; then
  cmd+=(--language "$ASR_LANGUAGE")
fi
if [[ "$PRINT_SEGMENTS" == "1" ]]; then
  cmd+=(--print-segments)
fi
if [[ "$VAD_FILTER" == "1" ]]; then
  cmd+=(--vad-filter)
fi
if [[ "$DIARIZE" == "1" ]]; then
  cmd+=(--diarize)
  if [[ "$DIARIZE_TEMP" == "1" ]]; then
    cmd+=(--diarize-temp)
  fi
fi

"${cmd[@]}"
