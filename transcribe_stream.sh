#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: transcribe_stream.sh [options] [INPUT]

options:
  --input TYPE:SOURCE    (e.g. pulse:default or url:https://...)
  --input-type TYPE      (pulse|url) (default: pulse)
  --input SOURCE         (default: from positional INPUT)
  --model NAME           (default: medium)
  --language CODE        (default: auto)
  --diarize / --no-diarize
  --diarize-no-smooth
  --diarize-min-words N
  --diarize-min-duration SEC
  --print-segments / --no-print-segments
  --chunk-sec N          (default: 20)
  --overlap-sec N        (default: 2)
  --media-dir PATH       (default: /home/sasha/projects/mp3-transcribe/Media)
  --output-file PATH     (default: Media/stream_transcript_YYYYmmdd_HHMMSS.txt)
  --record-mp3 PATH      (default: Media/stream_record_YYYYmmdd_HHMMSS.mp3)
  --no-record-mp3
  --keep-chunks / --no-keep-chunks (default: keep)
  --clear-chunks / --no-clear-chunks (default: clear)
  --compute-type TYPE    (default: int8)
  --beam-size N          (default: 5)
  --venv PATH            (default: /home/sasha/projects/mp3-transcribe/.venv)
  -h, --help             show this help

examples:
  transcribe_stream.sh --input pulse:default
  transcribe_stream.sh --input-type pulse --input alsa_output.pci-0000_00_1f.3.analog-stereo.monitor
  transcribe_stream.sh --input url:https://example.com/stream
USAGE
}

list_pulse_sources() {
  if command -v pactl >/dev/null 2>&1; then
    echo "[info] PulseAudio sources:"
    pactl list short sources || true
    echo
    echo "Tip: use a *monitor* source for desktop audio."
  else
    echo "[err] pactl not found; cannot list PulseAudio sources." >&2
  fi
}

# Defaults
VENV="/home/sasha/projects/mp3-transcribe/.venv"
MEDIA_DIR="/home/sasha/projects/mp3-transcribe/Media"
MODEL="medium"
COMPUTE_TYPE="int8"
BEAM_SIZE="5"
DIARIZE=0
DIARIZE_TEMP=0
DIARIZE_SMOOTH=1
DIARIZE_MIN_WORDS=""
DIARIZE_MIN_DURATION=""
ASR_LANGUAGE=""
PRINT_SEGMENTS=1
CHUNK_SEC=20
OVERLAP_SEC=2
INPUT_TYPE="pulse"
INPUT=""
OUTPUT_FILE=""
RECORD_MP3=""
KEEP_CHUNKS=1
CLEAR_CHUNKS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      if [[ $# -lt 2 || "$2" == "-"* ]]; then
        INPUT=""
        shift
        continue
      fi
      if [[ "$2" == *:* ]]; then
        INPUT_TYPE="${2%%:*}"
        INPUT="${2#*:}"
      else
        INPUT="$2"
      fi
      shift 2;;
    --input-type) INPUT_TYPE="$2"; shift 2;;
    --input-source|--input-src|--input-path|--input-url|--input-device|--input-name|--input-id|--input-value|--input-file|--input-arg) INPUT="$2"; shift 2;;
    --model) MODEL="$2"; shift 2;;
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
    --chunk-sec) CHUNK_SEC="$2"; shift 2;;
    --overlap-sec) OVERLAP_SEC="$2"; shift 2;;
    --media-dir) MEDIA_DIR="$2"; shift 2;;
    --output-file) OUTPUT_FILE="$2"; shift 2;;
    --record-mp3) RECORD_MP3="$2"; shift 2;;
    --no-record-mp3) RECORD_MP3=""; shift;;
    --keep-chunks) KEEP_CHUNKS=1; shift;;
    --no-keep-chunks) KEEP_CHUNKS=0; shift;;
    --clear-chunks) CLEAR_CHUNKS=1; shift;;
    --no-clear-chunks) CLEAR_CHUNKS=0; shift;;
    --compute-type) COMPUTE_TYPE="$2"; shift 2;;
    --beam-size) BEAM_SIZE="$2"; shift 2;;
    --venv) VENV="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    --) shift; break;;
    -*) echo "[err] unknown option: $1" >&2; usage; exit 2;;
    *)
      if [[ -z "$INPUT" ]]; then
        INPUT="$1"
      fi
      shift;;
  esac
done

if [[ -z "$INPUT" ]]; then
  if [[ "$INPUT_TYPE" == "pulse" ]]; then
    usage
    echo
    list_pulse_sources
    exit 1
  else
    usage
    exit 1
  fi
fi

if [[ ! -x "$VENV/bin/python" ]]; then
  echo "[err] venv not found: $VENV" >&2
  exit 1
fi

mkdir -p "$MEDIA_DIR"

if [[ -z "$OUTPUT_FILE" ]]; then
  timestamp="$(date +%Y%m%d_%H%M%S)"
  OUTPUT_FILE="$MEDIA_DIR/stream_transcript_${timestamp}.txt"
fi

if [[ -z "$RECORD_MP3" ]]; then
  timestamp="${timestamp:-$(date +%Y%m%d_%H%M%S)}"
  RECORD_MP3="$MEDIA_DIR/stream_record_${timestamp}.mp3"
fi

CHUNKS_DIR="$MEDIA_DIR/stream_chunks"
mkdir -p "$CHUNKS_DIR"

if [[ "$CLEAR_CHUNKS" == "1" ]]; then
  rm -f "$CHUNKS_DIR"/part*.wav "$CHUNKS_DIR"/*.json "$CHUNKS_DIR/.tail.wav" "$CHUNKS_DIR/.window.wav" "$CHUNKS_DIR/.last_speaker" || true
fi

touch "$OUTPUT_FILE"
echo "[stream] output: $OUTPUT_FILE"
if [[ -n "$RECORD_MP3" ]]; then
  echo "[stream] record: $RECORD_MP3"
else
  echo "[stream] record: disabled"
fi
echo "[stream] chunk_sec=$CHUNK_SEC overlap_sec=$OVERLAP_SEC"
echo "[stream] waiting for first chunk (~${CHUNK_SEC}s + transcription)..."

ffmpeg_args=(-hide_banner -loglevel error)
if [[ "$INPUT_TYPE" == "pulse" ]]; then
  ffmpeg_args+=(-f pulse -i "$INPUT")
else
  ffmpeg_args+=(-i "$INPUT")
fi

if [[ -n "$RECORD_MP3" ]]; then
  ffmpeg_args+=(-filter_complex "[0:a]asplit=2[a0][a1]" \
    -map "[a0]" -ac 1 -ar 16000 -c:a pcm_s16le -f segment -segment_time "$CHUNK_SEC" -reset_timestamps 1 "$CHUNKS_DIR/part%06d.wav" \
    -map "[a1]" -ac 1 -ar 16000 -c:a libmp3lame -b:a 128k "$RECORD_MP3")
else
  ffmpeg_args+=(-ac 1 -ar 16000 -c:a pcm_s16le -f segment -segment_time "$CHUNK_SEC" -reset_timestamps 1 "$CHUNKS_DIR/part%06d.wav")
fi

export HF_HUB_DISABLE_PROGRESS_BARS=0

# Start capture
ffmpeg "${ffmpeg_args[@]}" &
FFMPEG_PID=$!
trap 'kill "$FFMPEG_PID" >/dev/null 2>&1 || true' EXIT

last_speaker_file="$CHUNKS_DIR/.last_speaker"
idx=0
prev=""

while true; do
  file="$CHUNKS_DIR/part$(printf "%06d" "$idx").wav"
  if [[ -f "$file" ]]; then
    # Wait until file size stabilizes (ffmpeg finished writing the segment)
    last_size=""
    stable=0
    for _ in {1..5}; do
      size="$(stat -c%s "$file" 2>/dev/null || echo 0)"
      if [[ "$size" != "0" && "$size" == "$last_size" ]]; then
        stable=1
        break
      fi
      last_size="$size"
      sleep 1
    done
    if [[ "$stable" != "1" ]]; then
      sleep 1
      continue
    fi
    window="$file"
    if [[ -n "$prev" && "$OVERLAP_SEC" != "0" ]]; then
      tail="$CHUNKS_DIR/.tail.wav"
      window="$CHUNKS_DIR/.window.wav"
      if ! ffmpeg -hide_banner -loglevel error -y -sseof -"$OVERLAP_SEC" -i "$prev" -c copy "$tail"; then
        cp "$prev" "$tail"
      fi
      ffmpeg -hide_banner -loglevel error -y -i "$tail" -i "$file" \
        -filter_complex "[0:a][1:a]concat=n=2:v=0:a=1" "$window"
    fi

    out_dir="$CHUNKS_DIR"
    out_json="$out_dir/$(basename "${window%.*}").json"

    cmd=("$VENV/bin/python" "/home/sasha/projects/mp3-transcribe/transcribe.py" "$window"
         --model "$MODEL" --format json --output-dir "$out_dir" --compute-type "$COMPUTE_TYPE" --beam-size "$BEAM_SIZE")
    if [[ -n "$ASR_LANGUAGE" ]]; then
      cmd+=(--language "$ASR_LANGUAGE")
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

    "${cmd[@]}" >/dev/null

    "$VENV/bin/python" - "$out_json" "$OVERLAP_SEC" "$OUTPUT_FILE" "$PRINT_SEGMENTS" "$last_speaker_file" <<'PY'
import json
import os
import sys

path = sys.argv[1]
overlap = float(sys.argv[2])
output_file = sys.argv[3]
print_segments = sys.argv[4] == "1"
last_speaker_file = sys.argv[5]

last_speaker = None
if os.path.exists(last_speaker_file):
    with open(last_speaker_file, "r", encoding="utf-8") as fh:
        last_speaker = fh.read().strip() or None

with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

lines = []
for seg in data.get("segments", []):
    end = float(seg.get("end", 0.0))
    if overlap > 0 and end <= overlap:
        continue
    text = (seg.get("text") or "").strip()
    if not text:
        continue
    speaker = seg.get("speaker")
    if speaker:
        if speaker != last_speaker:
            text = f"{speaker}: {text}"
        last_speaker = speaker
    lines.append(text)

if lines:
    with open(output_file, "a", encoding="utf-8") as fh:
        for line in lines:
            fh.write(line + "\n")
            if print_segments:
                print(line, flush=True)

if last_speaker is not None:
    with open(last_speaker_file, "w", encoding="utf-8") as fh:
        fh.write(last_speaker)
PY

    prev="$file"
    idx=$((idx + 1))

    if [[ "$KEEP_CHUNKS" == "0" ]]; then
      rm -f "$file" "$out_json" "$CHUNKS_DIR/.tail.wav" "$CHUNKS_DIR/.window.wav" || true
    fi
  else
    sleep 1
  fi
done
