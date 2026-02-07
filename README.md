# mp3-transcribe (CPU)

CPU‑only transcription toolkit built on **faster‑whisper** with optional **speaker diarization** (pyannote).
It supports single MP3 files, batch processing, and pseudo‑realtime streaming.
Outputs are written to a clean `Media/` folder by default, with live‑appending text for long files.

## Common use cases
1) **One file or batch from `Media/`**  
   - Transcribe a specific file, or scan `Media/` and process only the files
     that don’t have outputs yet.

2) **Live meeting capture (Zoom/Google Meet)** *(not fully tuned yet)*  
   - Start before a meeting to capture **system audio + microphone**.  
   - The stream mode will **transcribe in realtime**, **record a full MP3** of
     everything it hears, and **append to a transcript file**.  
   - **Diarization can be enabled** in stream mode, but it’s CPU‑heavy and still
     considered experimental in streaming, so treat it as “best effort.”

## Requirements
- Python 3.10+
- `ffmpeg` in PATH (needed for decoding)

## Media folder (default)
All input/output artifacts are written to `Media/` by default.
If you pass a filename without a path, scripts will try `Media/<file>`.

## Setup
```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Core usage (Python)
```bash
python transcribe.py /path/to/audio.mp3 --model medium
```

Other formats:
```bash
python transcribe.py /path/to/audio.mp3 --format srt
python transcribe.py /path/to/audio.mp3 --format json --word-timestamps
```

Notes:
- Any faster‑whisper model name works (tiny/base/small/medium/large‑v3...).
- Best CPU speed/quality default: `--compute-type int8`.
- Language is auto‑detected unless `--language` is provided.
- TXT is written **live** while transcribing; disable with `--no-write-live` (diarization forces non‑live output).

## Batch processing (Media by default)
Transcribes supported audio files that don’t yet have .txt/.srt/.json outputs.
```bash
./transcribe_all.sh
```
Target another folder:
```bash
./transcribe_all.sh --target-dir /path/to/folder
```

Limit extensions:
```bash
./transcribe_all.sh --extensions mp3,ogg,wav
```

Create a merged transcript for this run (default on):
```bash
./transcribe_all.sh --merged-file /path/to/merged.txt
```

Disable merged output:
```bash
./transcribe_all.sh --no-merged
```

## Quick single‑file wrapper
Defaults: `model=medium`, `format=txt`, `diarize=off`, `compute_type=int8`.
```bash
./transcribe_one.sh /path/to/file.mp3
```

Example with options:
```bash
./transcribe_one.sh --model large-v3 --diarize --print-segments /path/to/file.mp3
```

## Speaker diarization (pyannote)
Requires a Hugging Face token in `.env`:
```
HF_TOKEN=...
```

Install diarization deps:
```bash
pip install -r requirements-diarization.txt
```

Run:
```bash
python transcribe.py /path/to/audio.mp3 --model large-v3 --diarize --format txt
```

Notes:
- Diarization is CPU‑heavy.
- Speaker labels are inserted as `SPEAKER_00: ...`.
- By default, **smoothing is ON** to reduce rapid speaker flicker.
  Default smoothing thresholds: `--diarize-min-words 3`, `--diarize-min-duration 0.5`.
  To preserve very short interjections, use `--diarize-no-smooth` or lower thresholds.
- By default, diarization runs **without a temporary WAV** (no big files on disk).
  If needed, force WAV mode: `--diarize-temp`.

## Streaming (pseudo‑realtime)
Splits the incoming stream into chunks and transcribes continuously.
Writes both a live transcript and an MP3 recording in `Media/`.

Example (PulseAudio):
```bash
./transcribe_stream.sh --input pulse:default
```

Parameters:
- `--chunk-sec` (default 20)
- `--overlap-sec` (default 2) — protects against word cuts
- `--output-file` (default `Media/stream_transcript_YYYYmmdd_HHMMSS.txt`)
- `--record-mp3` (default `Media/stream_record_YYYYmmdd_HHMMSS.mp3`)
- `--media-dir` (default `Media/`)
- `--clear-chunks` / `--no-clear-chunks` (default clears old chunks)
- `--model`, `--language`, `--diarize`, `--print-segments`

Note: output appears after the first chunk closes (≈ `chunk-sec` + ASR time).

PulseAudio tip (desktop audio):
```bash
pactl list short sources
```
Use a `*.monitor` source for system audio (e.g., `alsa_output...monitor`).

## Help
All wrappers support `--help`:
```bash
./transcribe_one.sh --help
./transcribe_all.sh --help
./transcribe_stream.sh --help
```
