#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: transcribe_all.sh [options]

options:
  --model NAME            (default: medium)
  --format txt|srt|json    (default: txt)
  --compute-type TYPE     (default: int8)
  --beam-size N           (default: 5)
  --language CODE         (default: auto)
  --diarize / --no-diarize
  --diarize-no-smooth
  --diarize-min-words N
  --diarize-min-duration SEC
  --print-segments / --no-print-segments
  --vad-filter / --no-vad-filter
  --media-dir PATH        (default: /home/sasha/projects/mp3-transcribe/Media)
  --target-dir PATH       (default: MEDIA_DIR)
  --output-dir PATH       (default: TARGET_DIR)
  --recursive             (scan subfolders)
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
DIARIZE_SMOOTH=1
DIARIZE_MIN_WORDS=""
DIARIZE_MIN_DURATION=""
ASR_LANGUAGE=""
TARGET_DIR=""
OUTPUT_DIR=""
RECURSIVE=0

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
    --diarize-no-smooth) DIARIZE_SMOOTH=0; shift;;
    --diarize-min-words) DIARIZE_MIN_WORDS="$2"; shift 2;;
    --diarize-min-duration) DIARIZE_MIN_DURATION="$2"; shift 2;;
    --print-segments) PRINT_SEGMENTS=1; shift;;
    --no-print-segments) PRINT_SEGMENTS=0; shift;;
    --vad-filter) VAD_FILTER=1; shift;;
    --no-vad-filter) VAD_FILTER=0; shift;;
    --media-dir) MEDIA_DIR="$2"; shift 2;;
    --target-dir) TARGET_DIR="$2"; shift 2;;
    --output-dir) OUTPUT_DIR="$2"; shift 2;;
    --recursive) RECURSIVE=1; shift;;
    --venv) VENV="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    --) shift; break;;
    -*) echo "[err] unknown option: $1" >&2; usage; exit 2;;
    *) shift;;
  esac
done

export HF_HUB_DISABLE_PROGRESS_BARS=0

if [[ ! -x "$VENV/bin/python" ]]; then
  echo "[err] venv not found: $VENV" >&2
  exit 1
fi

if [[ -z "$TARGET_DIR" ]]; then
  TARGET_DIR="$MEDIA_DIR"
fi
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$TARGET_DIR"
fi

shopt -s nullglob
if [[ "$RECURSIVE" == "1" ]]; then
  mapfile -t files < <(find "$TARGET_DIR" -type f -name '*.mp3' | sort)
else
  files=("$TARGET_DIR"/*.mp3)
fi

if [[ ${#files[@]} -eq 0 ]]; then
  echo "[info] mp3 files not found in $TARGET_DIR"
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
       --model "$MODEL" --format "$FORMAT" --compute-type "$COMPUTE_TYPE" --beam-size "$BEAM_SIZE" --output-dir "$OUTPUT_DIR")
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
    if [[ "$DIARIZE_SMOOTH" == "0" ]]; then
      cmd+=(--diarize-no-smooth)
    fi
    if [[ -n "$DIARIZE_MIN_WORDS" ]]; then
      cmd+=(--diarize-min-words "$DIARIZE_MIN_WORDS")
    fi
    if [[ -n "$DIARIZE_MIN_DURATION" ]]; then
      cmd+=(--diarize-min-duration "$DIARIZE_MIN_DURATION")
    fi
  fi

  "${cmd[@]}"
  echo
 done
