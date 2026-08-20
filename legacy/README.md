# legacy — the BlackHole approach

Kept for reference. **Do not use this for new recordings.**

`blackhole-record.sh` routes system audio through the BlackHole virtual driver
and a Multi-Output Device, then captures it with ffmpeg's avfoundation input.

It works, but on macOS 26 it loses roughly **6–7% of the audio**: a `-t 60`
recording produces a ~56-second file, audible as pops and a rushed tempo. The
cause is buffer drops in ffmpeg's avfoundation capture. avfoundation timestamps
keep advancing in real time regardless, so ffmpeg stops at 60 seconds of
*timestamps* while only 56 seconds of *samples* exist — and a WAV stores
samples, not timestamps.

This was checked thoroughly before being abandoned:

- every capture-path device verified at a matching 48000 Hz
- BlackHole Clock Source set to Internal Fixed
- Multi-Output bypassed entirely — the loss was unchanged, so the aggregate
  device is not the cause
- `-thread_queue_size` raised — no effect
- loss measured flat across 5/10/20/40-second tones, so fixed-rate rather than
  accumulating
- confirmed against a real recording by ear and by file duration, not only by
  the synthetic tone test

`--resync` mitigates but does not fix it: it pads the gaps so audio keeps
correct duration and pitch, turning "everything plays 7% fast" into "correct
tempo with brief dropouts". The audio is still gone.

Use `taprec` instead. On macOS 14.2+ there is no reason to use this.

## Tools that go with it

- `../tools/diagnose-audio.sh` — tone-based capture diagnostics. Plays a known
  tone, measures the captured result for speed error, dropped content and
  clicks. `--selftest` validates the measuring chain itself with no audio
  hardware involved, which is worth running before trusting any of its numbers.
- `../tools/compare-capture.sh` — A/B different capture configurations against
  the same tone; `--sweep` shows how loss scales with recording length.
