#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
from pathlib import Path

from faster_whisper import WhisperModel

# Optional imports for diarization without temp WAV.
try:
    from pyannote.audio.core.io import Audio, AudioDecoder
    import torch.nn.functional as F
except Exception:  # pragma: no cover
    Audio = None
    AudioDecoder = None
    F = None

MEDIA_DIR = Path("Media")

if Audio is not None:
    class TolerantAudio(Audio):  # type: ignore[misc]
        """Audio crop that tolerates sample-count mismatches (MP3/VBR quirks)."""

        def crop(self, file, segment, mode="raise"):
            file = self.validate_file(file)
            channel = file.get("channel", None)

            # in-memory waveform path
            if "waveform" in file:
                waveform = file["waveform"]
                _, num_samples = waveform.shape
                sample_rate = file["sample_rate"]
                duration = num_samples / sample_rate

                start_sample = self.get_num_samples(segment.start, sample_rate)
                pad_start = max(0, -start_sample)
                if start_sample < 0:
                    if mode == "raise":
                        raise ValueError(
                            f"requested chunk with negative start time (t={segment.start:.3f}s)"
                        )
                    start_sample = 0

                end_sample = self.get_num_samples(segment.end, sample_rate)
                pad_end = max(end_sample, num_samples) - num_samples
                if end_sample >= num_samples:
                    if mode == "raise":
                        raise ValueError(
                            f"requested chunk with end time (t={segment.end:.3f}s) greater than "
                            f"{file.get('uri', 'in-memory')} file duration ({duration:.3f}s)."
                        )
                    end_sample = num_samples

                data = waveform[:, start_sample:end_sample]
                data = F.pad(data, (pad_start, pad_end))
                return self.downmix_and_resample(data, sample_rate, channel=channel)

            decoder = AudioDecoder(
                file["audio"],
                sample_rate=self.sample_rate,
                num_channels=1 if self.mono else None,
            )
            metadata = decoder.metadata

            sample_rate = metadata.sample_rate
            duration = metadata.duration_seconds_from_header
            num_samples = self.get_num_samples(duration, sample_rate)

            start = float(segment.start)
            end = float(segment.end)

            pad_start = max(0, self.get_num_samples(-start, sample_rate))
            if start < 0:
                if mode == "raise":
                    raise ValueError(
                        f"requested chunk with negative start time (t={start:.3f}s)"
                    )
                start = 0.0

            pad_end = max(self.get_num_samples(end, sample_rate), num_samples) - num_samples
            if end > duration:
                if mode == "raise":
                    raise ValueError(
                        f"requested chunk with end time (t={end:.3f}s) greater than "
                        f"{file.get('uri', 'in-memory')} file duration ({duration:.3f}s)."
                    )
                end = duration

            samples = decoder.get_samples_played_in_range(start, end)
            data = samples.data
            sample_rate = samples.sample_rate

            expected = self.get_num_samples(segment.duration, sample_rate)
            _, actual = data.shape
            difference = pad_start + actual + pad_end - expected
            if difference > 0:
                trim = min(actual, difference)
                if trim > 0:
                    data = data[:, :-trim]
            elif difference < 0:
                pad_end += -difference

            data = F.pad(data, (pad_start, pad_end))
            return self.downmix_and_resample(data, sample_rate, channel=channel)
else:
    TolerantAudio = None

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
        "--write-live",
        dest="write_live",
        action="store_true",
        help="Писать TXT по мере распознавания (без диаризации).",
    )
    parser.add_argument(
        "--no-write-live",
        dest="write_live",
        action="store_false",
        help="Отключить live-запись в TXT.",
    )
    parser.set_defaults(write_live=True)
    parser.add_argument(
        "--diarize",
        action="store_true",
        help="Включить диаризацию спикеров (pyannote). Требует HF_TOKEN.",
    )
    parser.add_argument(
        "--diarize-smooth",
        dest="diarize_smooth",
        action="store_true",
        help="Сглаживать частые переключения спикеров (по умолчанию).",
    )
    parser.add_argument(
        "--diarize-no-smooth",
        dest="diarize_smooth",
        action="store_false",
        help="Не сглаживать переключения спикеров.",
    )
    parser.set_defaults(diarize_smooth=True)
    parser.add_argument(
        "--diarize-min-words",
        type=int,
        default=3,
        help="Минимум слов для сохранения короткой реплики при сглаживании.",
    )
    parser.add_argument(
        "--diarize-min-duration",
        type=float,
        default=0.5,
        help="Минимальная длительность (сек) для сохранения короткой реплики при сглаживании.",
    )
    parser.add_argument(
        "--diarize-temp",
        dest="diarize_temp",
        action="store_true",
        help="Использовать временный WAV для диаризации (занимает место).",
    )
    parser.add_argument(
        "--diarize-no-temp",
        dest="diarize_temp",
        action="store_false",
        help="Диаризация без временного WAV (по умолчанию).",
    )
    parser.set_defaults(diarize_temp=False)
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
    lines = []
    current_speaker = None
    current_text = []

    def flush_current():
        if not current_text:
            return
        joined = " ".join(current_text).strip()
        if current_speaker:
            joined = f"{current_speaker}: {joined}"
        lines.append(joined)
        current_text.clear()

    for seg in segments:
        text = seg.text.strip()
        if not text:
            continue
        speaker = getattr(seg, "speaker", None)
        if speaker:
            if current_speaker is None:
                current_speaker = speaker
            if speaker != current_speaker:
                flush_current()
                current_speaker = speaker
            current_text.append(text)
        else:
            flush_current()
            current_speaker = None
            lines.append(text)

    flush_current()
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


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
    output_dir = Path(args.output_dir) if args.output_dir else MEDIA_DIR
    output_dir.mkdir(parents=True, exist_ok=True)
    out_path = output_dir / f"{audio_path.stem}.{args.format}"

    print(f"[start] {audio_path.name}", flush=True)
    start_time = time.time()
    word_ts = args.word_timestamps
    if args.diarize and not word_ts:
        word_ts = True
    segments, info = model.transcribe(
        str(audio_path),
        language=args.language,
        beam_size=args.beam_size,
        vad_filter=args.vad_filter,
        word_timestamps=word_ts,
    )
    collected = []
    live_write = args.write_live and args.format == "txt" and not args.diarize
    live_fh = None
    if live_write:
        live_fh = out_path.open("w", encoding="utf-8")
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
        if live_fh is not None:
            text = seg.text.strip()
            if text:
                live_fh.write(text + "\n")
                live_fh.flush()

    if args.diarize:
        collected = apply_diarization(audio_path, collected, args)

    if args.format == "txt":
        if live_fh is None:
            write_txt(out_path, collected)
    elif args.format == "srt":
        write_srt(out_path, collected)
    else:
        write_json(out_path, collected, info, args.word_timestamps)

    if live_fh is not None:
        live_fh.close()

    elapsed = time.time() - start_time
    print(f"[ok] {audio_path.name} -> {out_path.name} ({elapsed:.1f}s)")


def main() -> int:
    args = parse_args()
    load_env_file(Path(".env"))
    input_path = Path(args.input)
    if not input_path.exists() and not input_path.is_absolute():
        media_candidate = MEDIA_DIR / input_path
        if media_candidate.exists():
            input_path = media_candidate
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


def apply_diarization(audio_path: Path, segments, args: argparse.Namespace):
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

    if not args.diarize_temp:
        if Audio is None or AudioDecoder is None or F is None:
            print("[err] diarize no-temp requires pyannote.audio", file=sys.stderr)
            return
        pipeline._audio = TolerantAudio(sample_rate=16000, mono="downmix")
        try:
            diarization = pipeline(str(audio_path))
        except Exception as exc:
            print(f"[err] diarize run failed: {exc}", file=sys.stderr)
            return
    else:
        tmp_wav = None
        wav_path = None
        try:
            tmp_wav = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
            tmp_wav.close()
            wav_path = tmp_wav.name
            ffmpeg_cmd = [
                "ffmpeg",
                "-y",
                "-hide_banner",
                "-loglevel",
                "error",
                "-i",
                str(audio_path),
                "-ac",
                "1",
                "-ar",
                "16000",
                wav_path,
            ]
            subprocess.run(ffmpeg_cmd, check=True)
        except Exception as exc:
            print(f"[err] diarize prep failed: {exc}", file=sys.stderr)
            if wav_path:
                try:
                    os.unlink(wav_path)
                except OSError:
                    pass
            return

        try:
            diarization = pipeline(wav_path)
        except Exception as exc:
            print(f"[err] diarize run failed: {exc}", file=sys.stderr)
            if wav_path:
                try:
                    os.unlink(wav_path)
                except OSError:
                    pass
            return
        finally:
            if wav_path:
                try:
                    os.unlink(wav_path)
                except OSError:
                    pass

    speaker_spans = []
    if hasattr(diarization, "itertracks"):
        for turn, _, speaker in diarization.itertracks(yield_label=True):
            speaker_spans.append((turn.start, turn.end, speaker))
    elif hasattr(diarization, "annotation"):
        for turn, _, speaker in diarization.annotation.itertracks(yield_label=True):
            speaker_spans.append((turn.start, turn.end, speaker))
    elif hasattr(diarization, "speaker_diarization"):
        annotation = diarization.speaker_diarization
        for turn, _, speaker in annotation.itertracks(yield_label=True):
            speaker_spans.append((turn.start, turn.end, speaker))
    elif hasattr(diarization, "to_annotation"):
        annotation = diarization.to_annotation()
        for turn, _, speaker in annotation.itertracks(yield_label=True):
            speaker_spans.append((turn.start, turn.end, speaker))
    elif isinstance(diarization, dict) and "annotation" in diarization:
        for turn, _, speaker in diarization["annotation"].itertracks(yield_label=True):
            speaker_spans.append((turn.start, turn.end, speaker))
    else:
        print(
            f"[err] unknown diarization output format: {type(diarization)}",
            file=sys.stderr,
        )
        return segments

    if not speaker_spans:
        print("[diarize] пусто", flush=True)
        return

    if any(getattr(seg, "words", None) for seg in segments):
        return build_segments_from_words(segments, speaker_spans, args)

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

    return segments


def speaker_for_time(t: float, spans) -> str | None:
    for sp_start, sp_end, speaker in spans:
        if sp_start <= t <= sp_end:
            return speaker
    best_speaker = None
    best_overlap = 0.0
    for sp_start, sp_end, speaker in spans:
        overlap = max(0.0, min(t + 0.01, sp_end) - max(t - 0.01, sp_start))
        if overlap > best_overlap:
            best_overlap = overlap
            best_speaker = speaker
    return best_speaker


def build_segments_from_words(segments, speaker_spans, args):
    out = []
    current = None
    for seg in segments:
        words = getattr(seg, "words", None) or []
        for w in words:
            mid = (w.start + w.end) / 2.0
            speaker = speaker_for_time(mid, speaker_spans)
            if current is None or current.speaker != speaker:
                if current is not None:
                    out.append(current)
                current = SimpleNamespace(
                    id=len(out),
                    start=w.start,
                    end=w.end,
                    text=w.word,
                    speaker=speaker,
                    words=[w],
                )
            else:
                current.end = w.end
                current.text += w.word
                current.words.append(w)
        if not words:
            out.append(seg)

    if current is not None:
        out.append(current)
    if args.diarize_smooth:
        return smooth_speaker_segments(
            out,
            min_words=args.diarize_min_words,
            min_duration=args.diarize_min_duration,
        )
    return out


def smooth_speaker_segments(segments, min_words=3, min_duration=0.7):
    if not segments:
        return segments
    # First pass: merge very short segments into the next one.
    merged = []
    i = 0
    while i < len(segments):
        seg = segments[i]
        words = getattr(seg, "words", None) or []
        duration = seg.end - seg.start

        if (len(words) < min_words or duration < min_duration) and i + 1 < len(segments):
            nxt = segments[i + 1]
            nxt.text = seg.text + nxt.text
            nxt.start = seg.start
            if getattr(nxt, "words", None) is not None and words:
                nxt.words = words + nxt.words
            i += 1
            continue

        merged.append(seg)
        i += 1

    # Second pass: collapse short A-B-A islands.
    changed = True
    while changed and len(merged) >= 3:
        changed = False
        for i in range(1, len(merged) - 1):
            prev = merged[i - 1]
            cur = merged[i]
            nxt = merged[i + 1]
            if (
                getattr(prev, "speaker", None)
                and getattr(prev, "speaker", None) == getattr(nxt, "speaker", None)
                and getattr(cur, "speaker", None) != getattr(prev, "speaker", None)
            ):
                words = getattr(cur, "words", None) or []
                duration = cur.end - cur.start
                if len(words) < min_words or duration < min_duration:
                    prev.text += cur.text
                    prev.end = cur.end
                    if getattr(prev, "words", None) is not None and words:
                        prev.words += words
                    merged.pop(i)
                    changed = True
                    break

    # Final pass: merge consecutive same-speaker segments.
    result = []
    for seg in merged:
        words = getattr(seg, "words", None) or []
        if result and getattr(seg, "speaker", None) == getattr(result[-1], "speaker", None):
            prev = result[-1]
            prev.text += seg.text
            prev.end = seg.end
            if getattr(prev, "words", None) is not None and words:
                prev.words += words
        else:
            result.append(seg)
    return result


if __name__ == "__main__":
    raise SystemExit(main())
