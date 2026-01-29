# Dockerized processing: concept and options

## Concept / goal
Keep **Python only inside Docker**, while still supporting:
- **batch processing** of uploaded audio (Nextcloud/VPS), and
- **local live streaming** (system audio + mic) for meetings.

The main constraint is that **audio capture is OS‑specific**, while CPU ASR/diarization
can be containerized. This document summarizes the practical paths we discussed.

---

## Conclusions (summary)
1) **Batch uploads (most practical on VPS):**
   - Use **host file sync** (e.g., Nextcloud) and let the container process new files.
   - Simple, reliable, and avoids audio device access in Docker.

2) **Live streaming (must be local):**
   - Audio capture should run **locally** on the desktop (not VPS).
   - To keep Python inside Docker, send audio into the container as a stream.

3) **Preferred transport for local stream → container:**
   - **TCP over localhost** (more reliable than UDP).
   - UDP is usually fine on localhost but can drop frames under load.
   - FIFO named pipe is the most reliable but more brittle; TCP is a good balance.

---

## Option A — VPS batch processing (recommended)
**Use when:** audio is recorded elsewhere and uploaded later.

**Flow:**
- Phone/desktop writes files → Nextcloud syncs to VPS.
- Docker container watches a folder and transcribes.
- Outputs written back to Nextcloud.

**Pros:**
- No device access in Docker.
- Easy to recover/retry.

**Cons:**
- Not realtime.

---

## Option C — Local live stream with Docker (TCP)
**Use when:** you need live transcription during a meeting.

### Architecture
- **Host:** capture audio (Pulse/ALSA) and send via TCP on localhost.
- **Container:** reads TCP stream and runs ASR/diarization.

### Why TCP
- Reliable transport (no drops if container is slow).
- Keeps everything local and simple.

### Conceptual commands
**Host (sender):**
```
ffmpeg -f pulse -i <source> -f mpegts tcp://127.0.0.1:5004
```

**Container (receiver):**
```
ffmpeg -i tcp://0.0.0.0:5004?listen=1 ... | python transcribe.py ...
```

### Notes
- Keep audio capture **outside** Docker, Python **inside** Docker.
- Expose TCP port from host to container (or use host network).
- Expect some added latency vs raw capture.

---

## Audio mixing (system + mic)
For mixed system audio + microphone on local machine:
- Create a virtual sink and record its `.monitor` source.
- Keep mic out of speakers to avoid feedback.

(See `ideas/MEDIA_AUDIO_MIX_SETUP.md` for full setup.)

---

## Limitations / caveats
- **Live diarization** is CPU‑heavy and “best‑effort” in streaming.
- Full realtime on CPU is not guaranteed for `medium/large` models.
- Audio capture is OS‑specific (PulseAudio/PipeWire on Linux).
