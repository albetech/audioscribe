#!/usr/bin/env python3
import argparse
import json
import os
import sys
import time
from pathlib import Path

from faster_whisper import WhisperModel


def format_timestamp(seconds: float) -> str:
    ms = int(seconds * 1000 + 0.5)
    h = ms // 3_600_000
    m = (ms % 3_600_000) // 60_000
    s = (ms % 60_000) // 1000
    ms = ms % 1000
    return f"{h:02}:{m:02}:{s:02},{ms:03}"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="CPU утилита для транскрибирования MP3 через faster-whisper."
    )
    parser.add_argument(
        "input",
        help="MP3 файл или папка с MP3",
    )
    parser.add_argument(
        "--model",
        default="medium",
        help="Имя модели faster-whisper (например: tiny, base, small, medium, large-v3).",
    )
    parser.add_argument(
        "--language",
        default=None,
        help="Код языка (например, ru, en). Если не указано, определяется автоматически.",
    )
    parser.add_argument(
        "--compute-type",
        default="int8",
        help="Тип вычислений для CPU: int8 (по умолчанию), int8_float16, float32.",
    )
    parser.add_argument(
        "--cpu-threads",
        type=int,
        default=0,
        help="Количество CPU потоков. 0 = авто.",
    )
    parser.add_argument(
        "--vad-filter",
        action="store_true",
        help="Включить VAD для отсечения тишины.",
    )
    parser.add_argument(
        "--beam-size",
        type=int,
        default=5,
        help="Размер beam search (качество/скорость).",
    )
    parser.add_argument(
        "--word-timestamps",
        action="store_true",
        help="Сохранять таймкоды слов (в JSON).",
    )
    parser.add_argument(
        "--diarize",
        action="store_true",
        help="Включить диаризацию спикеров (pyannote). Требует HF_TOKEN.",
    )
    parser.add_argument(
        "--diarize-model",
        default="pyannote/speaker-diarization-community-1",
        help="HF модель для диаризации.",
    )
    parser.add_argument(
        "--print-segments",
        action="store_true",
        help="Печатать сегменты по мере распознавания.",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="Папка вывода. По умолчанию рядом с исходником.",
    )
    parser.add_argument(
        "--format",
        choices=["txt", "srt", "json"],
        default="txt",
        help="Формат результата.",
    )
    parser.add_argument(
        "--recursive",
        action="store_true",
        help="Рекурсивно искать mp3 в папке.",
    )
    parser.add_argument(
        "--cache-dir",
        default=None,
        help="Папка кэша моделей.",
    )
    return parser.parse_args()


def resolve_inputs(path: Path, recursive: bool) -> list[Path]:
    if path.is_file():
        return [path]
    if path.is_dir():
        pattern = "**/*.mp3" if recursive else "*.mp3"
        return sorted(path.glob(pattern))
    return []


def write_txt(out_path: Path, segments) -> None:
    text = "".join(
        (f"{seg.speaker}: {seg.text}" if getattr(seg, "speaker", None) else seg.text)
        for seg in segments
    ).strip()
    out_path.write_text(text + "\n", encoding="utf-8")


def write_srt(out_path: Path, segments) -> None:
    lines = []
    for idx, seg in enumerate(segments, start=1):
        start = format_timestamp(seg.start)
        end = format_timestamp(seg.end)
        text = seg.text.strip()
        if getattr(seg, "speaker", None):
            text = f"{seg.speaker}: {text}"
        lines.append(f"{idx}")
        lines.append(f"{start} --> {end}")
        lines.append(text)
        lines.append("")
    out_path.write_text("\n".join(lines), encoding="utf-8")


def write_json(out_path: Path, segments, info, include_words: bool) -> None:
    payload = {
        "language": info.language,
        "language_probability": info.language_probability,
        "duration": info.duration,
        "segments": [],
    }
    for seg in segments:
        entry = {
            "id": seg.id,
            "start": seg.start,
            "end": seg.end,
            "text": seg.text,
        }
        if getattr(seg, "speaker", None):
            entry["speaker"] = seg.speaker
        if include_words and seg.words:
            entry["words"] = [
                {
                    "start": w.start,
                    "end": w.end,
                    "word": w.word,
                    "probability": w.probability,
                }
                for w in seg.words
            ]
        payload["segments"].append(entry)
    out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def transcribe_file(model: WhisperModel, audio_path: Path, args: argparse.Namespace) -> None:
    output_dir = Path(args.output_dir) if args.output_dir else audio_path.parent
    output_dir.mkdir(parents=True, exist_ok=True)
    out_path = output_dir / f"{audio_path.stem}.{args.format}"

    print(f"[start] {audio_path.name}", flush=True)
    start_time = time.time()
    segments, info = model.transcribe(
        str(audio_path),
        language=args.language,
        beam_size=args.beam_size,
        vad_filter=args.vad_filter,
        word_timestamps=args.word_timestamps,
    )
    collected = []
    if info.language:
        print(
            f"[lang] {info.language} (p={info.language_probability:.2f}) dur={info.duration:.1f}s",
            flush=True,
        )
    for seg in segments:
        collected.append(seg)
        if args.print_segments:
            ts = f"{format_timestamp(seg.start)} --> {format_timestamp(seg.end)}"
            print(f"[seg] {ts} {seg.text.strip()}", flush=True)

    if args.diarize:
        apply_diarization(audio_path, collected, args)

    if args.format == "txt":
        write_txt(out_path, collected)
    elif args.format == "srt":
        write_srt(out_path, collected)
    else:
        write_json(out_path, collected, info, args.word_timestamps)

    elapsed = time.time() - start_time
    print(f"[ok] {audio_path.name} -> {out_path.name} ({elapsed:.1f}s)")


def main() -> int:
    args = parse_args()
    load_env_file(Path(".env"))
    input_path = Path(args.input)
    inputs = resolve_inputs(input_path, args.recursive)
    if not inputs:
        print("Не найдено MP3 файлов по указанному пути.", file=sys.stderr)
        return 2

    model_name = args.model
    cpu_threads = args.cpu_threads if args.cpu_threads > 0 else 0

    print(f"[load] model={model_name} device=cpu compute_type={args.compute_type}", flush=True)
    model = WhisperModel(
        model_name,
        device="cpu",
        compute_type=args.compute_type,
        cpu_threads=cpu_threads,
        download_root=args.cache_dir,
    )

    for audio_path in inputs:
        transcribe_file(model, audio_path, args)
    return 0


def load_env_file(path: Path) -> None:
    if not path.is_file():
        return
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip())
    except OSError:
        return


def apply_diarization(audio_path: Path, segments, args: argparse.Namespace) -> None:
    try:
        from pyannote.audio import Pipeline
        from huggingface_hub import HfApi
    except Exception as exc:  # pragma: no cover
        print(f"[err] pyannote not available: {exc}", file=sys.stderr)
        return

    token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_TOKEN")
    if not token:
        print("[err] HF_TOKEN не задан. Диаризация пропущена.", file=sys.stderr)
        return

    repos_to_check = {args.diarize_model}
    if args.diarize_model == "pyannote/speaker-diarization-3.1":
        repos_to_check.add("pyannote/segmentation-3.0")

    blocked = []
    for repo_id in repos_to_check:
        try:
            HfApi().model_info(repo_id, token=token)
        except Exception as exc:
            blocked.append((repo_id, exc))
    if blocked:
        print("[err] нет доступа к моделям:", file=sys.stderr)
        for repo_id, exc in blocked:
            print(f"  - {repo_id}: {exc}", file=sys.stderr)
        print(
            "[err] примите условия доступа для этих моделей на Hugging Face и повторите.",
            file=sys.stderr,
        )
        return

    print(f"[diarize] model={args.diarize_model}", flush=True)
    try:
        pipeline = Pipeline.from_pretrained(args.diarize_model, token=token)
    except Exception as exc:
        print(f"[err] diarize download failed: {exc}", file=sys.stderr)
        return
    try:
        diarization = pipeline(str(audio_path))
    except Exception as exc:
        print(f"[err] diarize run failed: {exc}", file=sys.stderr)
        return

    speaker_spans = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        speaker_spans.append((turn.start, turn.end, speaker))

    if not speaker_spans:
        print("[diarize] пусто", flush=True)
        return

    for seg in segments:
        seg_start = seg.start
        seg_end = seg.end
        best_speaker = None
        best_overlap = 0.0
        for sp_start, sp_end, speaker in speaker_spans:
            overlap = max(0.0, min(seg_end, sp_end) - max(seg_start, sp_start))
            if overlap > best_overlap:
                best_overlap = overlap
                best_speaker = speaker
        if best_speaker:
            setattr(seg, "speaker", best_speaker)


if __name__ == "__main__":
    raise SystemExit(main())
