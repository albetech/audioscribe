# mp3-transcribe (CPU)

Простая CLI-утилита для транскрибирования MP3 на CPU через faster-whisper.

## Требования
- Python 3.10+
- ffmpeg в PATH (нужен для декодирования mp3)

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

## Пакетная обработка текущей папки
Скрипт обработает только те .mp3, для которых ещё нет .txt/.srt/.json.

Пример:
./transcribe_all.sh

Параметры через переменные окружения:
MODEL=large-v3 FORMAT=txt LANGUAGE=ru VAD_FILTER=1 PRINT_SEGMENTS=1 BEAM_SIZE=5 COMPUTE_TYPE=int8 ./transcribe_all.sh

Примечания:
- Для прогресса загрузки моделей включён HF_HUB_DISABLE_PROGRESS_BARS=0.
- Скрипт использует venv в /home/sasha/projects/mp3-transcribe/.venv

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
