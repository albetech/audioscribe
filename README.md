# mp3-transcribe (CPU)

Простая CLI-утилита для транскрибирования MP3 на CPU через faster-whisper.

## Требования
- Python 3.10+
- ffmpeg в PATH (нужен для декодирования mp3)

## Папка Media
По умолчанию все входные/выходные файлы и артефакты пишутся в `Media/`.
Если файл задан без пути, скрипты попытаются найти его в `Media/`.

## Установка
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

## Использование
### Один файл (medium)
python transcribe.py /path/to/audio.mp3 --model medium

### Большая модель
python transcribe.py /path/to/audio.mp3 --model large-v3

### SRT
python transcribe.py /path/to/audio.mp3 --format srt

### JSON с таймкодами слов
python transcribe.py /path/to/audio.mp3 --format json --word-timestamps

### Папка с mp3
python transcribe.py /path/to/folder --recursive --format txt

## Примечания
- Можно указать любое имя модели faster-whisper (tiny, base, small, medium, large-v3 и т.д.).
- Для CPU лучше всего подходит --compute-type int8.
- По умолчанию язык определяется автоматически (если не задан --language).
- TXT пишется по мере распознавания; отключить можно флагом `--no-write-live` (диаризация выключает live-запись).

## Пакетная обработка (Media по умолчанию)
Скрипт обработает только те .mp3, для которых ещё нет .txt/.srt/.json.

Пример:
./transcribe_all.sh

Другой каталог:
./transcribe_all.sh --target-dir /path/to/folder

## Диаризация спикеров (pyannote)
Нужен HF токен (в `.env` как `HF_TOKEN=...`).

Установка зависимостей:
```
pip install -r requirements-diarization.txt
```

Запуск (по умолчанию используется `pyannote/speaker-diarization-community-1`):
```
python transcribe.py /path/to/audio.mp3 --model large-v3 --diarize --format txt
```

Примечания:
- Диаризация на CPU медленная.
- Метки спикеров добавляются к сегментам: `SPEAKER_00: ...`
- По умолчанию диаризация работает без временного WAV (без доп. места на диске).
- Если нужно принудительно через WAV: `--diarize-temp`.

## Быстрый запуск для одного файла
По умолчанию: model=medium, format=txt, diarize=off, compute_type=int8.

Пример:
./transcribe_one.sh /path/to/file.mp3

С параметрами:
./transcribe_one.sh --model large-v3 --diarize --print-segments /path/to/file.mp3

Язык можно задать флагом:
./transcribe_one.sh --language ru /path/to/file.mp3

## Стрим с экрана/микрофона (псевдо‑реалтайм)
Скрипт режет поток на чанки и транскрибирует по мере поступления,
выводя текст в консоль и дописывая в файл. Одновременно пишет mp3‑запись потока.

Пример (PulseAudio):
```
./transcribe_stream.sh --input pulse:default
```

Если `--input` передан пустым (например, `--input` без значения, или не указан) при `--input-type pulse`,
скрипт покажет список доступных источников (через `pactl list short sources`).

Параметры:
- `--chunk-sec` (по умолчанию 20)
- `--overlap-sec` (по умолчанию 2) — перекрытие для защиты от «разрезанных слов»
- `--output-file` (по умолчанию `Media/stream_transcript_YYYYmmdd_HHMMSS.txt`)
- `--record-mp3` (по умолчанию `Media/stream_record_YYYYmmdd_HHMMSS.mp3`)
- `--media-dir` (по умолчанию `Media/`)
- `--clear-chunks` / `--no-clear-chunks` (по умолчанию очистка старых чанков)
- `--model`, `--language`, `--diarize`, `--print-segments`

Примечание: вывод появится после первого чанка (≈ `chunk-sec` + время распознавания),\nтак как чанк обрабатывается только после его закрытия.

Подсказка для десктоп‑аудио (PulseAudio):
```
pactl list short sources
```
И использовать *monitor*‑устройство (например, `alsa_output...monitor`).
