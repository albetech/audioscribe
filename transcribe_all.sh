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
  --media-dir PATH        (default: /home/sasha/projects/mp3-transcribe/Media)
  --target-dir PATH       (default: MEDIA_DIR)
  --output-dir PATH       (default: TARGET_DIR)
  --recursive             (scan subfolders)
  --extensions LIST       (comma list, default: mp3,ogg,wav,flac,m4a,opus,webm,mp4,aac)
  --merged-file PATH      (default: Media/merged_YYYYmmdd_HHMMSS.txt)
  --no-merged             (disable merged output)
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
TARGET_DIR=""
OUTPUT_DIR=""
RECURSIVE=0
EXTENSIONS="mp3,ogg,wav,flac,m4a,opus,webm,mp4,aac"
MERGED_FILE=""
MERGED_ENABLED=1

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
    --media-dir) MEDIA_DIR="$2"; shift 2;;
    --target-dir) TARGET_DIR="$2"; shift 2;;
    --output-dir) OUTPUT_DIR="$2"; shift 2;;
    --recursive) RECURSIVE=1; shift;;
    --extensions) EXTENSIONS="$2"; shift 2;;
    --merged-file) MERGED_FILE="$2"; shift 2;;
    --no-merged) MERGED_ENABLED=0; shift;;
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

if [[ "$MERGED_ENABLED" == "1" && -z "$MERGED_FILE" ]]; then
  ts="$(date +%Y%m%d_%H%M%S)"
  MERGED_FILE="$MEDIA_DIR/merged_${ts}.txt"
fi

if [[ "$MERGED_ENABLED" == "1" ]]; then
  : > "$MERGED_FILE"
fi

IFS=',' read -r -a exts <<<"$EXTENSIONS"

files=()
if [[ "$RECURSIVE" == "1" ]]; then
  for ext in "${exts[@]}"; do
    while IFS= read -r -d '' f; do
      files+=("$f")
    done < <(find "$TARGET_DIR" -type f -iname "*.${ext}" -print0)
  done
else
  shopt -s nullglob
  for ext in "${exts[@]}"; do
    files+=("$TARGET_DIR"/*."${ext}")
    files+=("$TARGET_DIR"/*."${ext^^}")
  done
fi

if [[ ${#files[@]} -eq 0 ]]; then
  echo "[info] audio files not found in $TARGET_DIR"
  exit 0
fi

mapfile -t files < <(printf '%s\n' "${files[@]}" | sort)

for f in "${files[@]}"; do
  base="${f%.*}"
  if [[ -f "${base}.txt" || -f "${base}.srt" || -f "${base}.json" ]]; then
    echo "[skip] $f (output exists)"
    continue
  fi

  echo "[file] $f"
  cmd=("$VENV/bin/python" "/home/sasha/projects/mp3-transcribe/transcribe.py" "$f"
       --model "$MODEL" --format "$FORMAT" --compute-type "$COMPUTE_TYPE" --beam-size "$BEAM_SIZE" --output-dir "$OUTPUT_DIR")
  if [[ -n "${ASR_LANGUAGE:-}" ]]; then
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

  if [[ "$MERGED_ENABLED" == "1" && "$FORMAT" == "txt" ]]; then
    out_path="$OUTPUT_DIR/$(basename "${base}").txt"
    if [[ -f "$out_path" ]]; then
      cat "$out_path" >> "$MERGED_FILE"
      printf "\n" >> "$MERGED_FILE"
    fi
  fi
  echo
 done
