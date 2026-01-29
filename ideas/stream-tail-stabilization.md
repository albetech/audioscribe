# Stream tail stabilization (idea)

## Problem
In streaming ASR, chunk boundaries can cut words. Even with overlap, the model may output
partial or incorrect words at the end of a chunk. We want to avoid inserting unstable text.

## Goal
Only emit **stable** text in realtime. Keep the last N seconds (“tail”) on the server and
flush it later when more context is available.

---

## Approach A — segment‑based tail
Whisper provides per‑segment timestamps (`start`, `end`).

For each processed window:
- let `cutoff = window_end - tail_sec`
- **emit only segments with `end <= cutoff`**
- keep anything after `cutoff` as the current tail

This is simple and doesn’t need word timestamps.

---

## Approach B — absolute timeline
Maintain a global clock across chunks:
- track `window_start` and `window_end` in absolute time
- compute `cutoff = now - tail_sec`
- emit segments with `end <= cutoff` and `end > emitted_until`

This avoids duplicates and works well with overlap.

---

## Approach C — word‑level tail
Enable `word_timestamps`:
- keep the last N seconds of **words**
- emit only words ending before `cutoff`
- optionally re‑segment text by speaker

Best accuracy, highest CPU cost.

---

## Notes
- Default `tail_sec` could be 1–3 seconds.
- Larger tail → more stable, but higher latency.
- Tail stabilization is especially useful for live dictation (push‑to‑talk).
