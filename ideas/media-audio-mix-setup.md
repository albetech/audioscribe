# Mix audio (system + mic) for streaming/transcription

This setup creates a virtual PulseAudio/ PipeWire sink named `Mix` so you can
capture *system audio + microphone* together without hearing yourself in the speakers.

## Goal
- **Speakers**: only system audio (YouTube/Zoom/etc.)
- **Mix.monitor**: system audio + microphone (for transcription/recording)

## Setup (no mic in speakers)
```bash
# 1) Create a virtual sink
pactl load-module module-null-sink sink_name=Mix sink_properties=device.description=Mix

# 2) Copy SYSTEM audio into Mix (system audio stays on speakers)
pactl load-module module-loopback source=alsa_output.pci-0000_05_00.6.analog-stereo.monitor sink=Mix latency_msec=50

# 3) Add MIC into Mix (recording only, not to speakers)
pactl load-module module-loopback source=alsa_input.pci-0000_05_00.6.analog-stereo sink=Mix latency_msec=50
```

## Start transcription from the mixed stream
```bash
./transcribe_stream.sh --input pulse:Mix.monitor --chunk-sec 5
```

## Optional: list devices
```bash
pactl list short sources
pactl list short sinks
```

## Tear down
Find module IDs:
```bash
pactl list short modules | rg Mix
```
Unload them:
```bash
pactl unload-module <ID>
```

## Notes
- If you use speakers, mic can still pick up sound acoustically. Headphones are better.
- You can adjust latency with `latency_msec=50` (try 100 if you hear crackles).
