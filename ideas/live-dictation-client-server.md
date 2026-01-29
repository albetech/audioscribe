# Live dictation: client/server over WSS

## Concept
Split the system into two roles:
- **Client (local):** captures audio, sends it to a remote server, and inserts text back into the active cursor position in real time.
- **Server (Docker):** performs ASR/diarization and streams partial/final text back.

This keeps Python and heavy compute on the server while the client stays lightweight.
You can still run **client and server on the same host** if desired.

---

## Why WSS (WebSocket over HTTPS)
- Passes through most firewalls/proxies (looks like regular HTTPS traffic).
- Good library support in many languages.
- Persistent bi‑directional stream (audio up, text down).

---

## High‑level flow
1) **Push‑to‑talk hotkey (hold):** start capture.
2) Client streams compressed audio chunks → server (WSS).
3) Server runs ASR (+ optional diarization) and streams back text deltas.
4) Client inserts text at the cursor (X11/Wayland).
5) On hotkey release: finalize remaining audio and flush the text.

---

## Client responsibilities (local)
- **Capture:** mic / system / mixed audio (Pulse/PipeWire/ALSA).
- **Encode:** Opus/AAC to reduce bandwidth & CPU.
- **Transport:** WSS streaming to server.
- **Insert:** type text directly at cursor (no clipboard) via:
  - X11: `xdotool`
  - Wayland: `wtype` (fallback `ydotool` if needed)

---

## Server responsibilities (Docker)
- **Receive WSS stream** (audio frames).
- **Decode to PCM** (ffmpeg).
- **ASR:** faster‑whisper (CPU / GPU).
- **Diarization:** optional (pyannote) — CPU‑heavy.
- **Return text** as partial/final updates.

---

## Transport format (suggested)
**Audio:** Opus frames (low bitrate, good quality)
**Text:** JSON messages
```json
{ "text": "...", "final": false, "offset": 12 }
```

---

## Hotkey behavior
- **Hold key → record**
- **Release key → finalize**
- Insert text *live* every N seconds + final flush

---

## OS support notes
- **X11** (GNOME on Xorg): hotkeys and `xdotool` are easy.
- **Wayland**: requires compositor‑specific hotkeys; `wtype` usually works.
- Local audio capture is OS‑specific; server is OS‑agnostic.

---

## Open questions
- Chunk size and latency targets
- Partial vs final update policy
- Authentication and encryption strategy
