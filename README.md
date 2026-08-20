# taprec

Record macOS system audio to a file — whatever is coming out of your speakers —
without installing a virtual audio driver.

```bash
taprec -t 60                    # one minute to ./recordings/
taprec -f m4a -o interview.m4a  # AAC, explicit filename
taprec --only-pid $(pgrep -x Music)
```

Nothing is rerouted. No virtual driver, no aggregate device, no output
switching, no sample-rate matching. Your audio keeps playing exactly as it was
while the recording happens.

Requires **macOS 14.2+** (when Apple shipped the Core Audio taps API) and
`ffmpeg`.

---

## Why not BlackHole?

The usual advice is BlackHole plus a Multi-Output Device: route system audio
into a virtual driver and record that. It works, but it makes you responsible
for a lot of state — every device's sample rate, the aggregate's clock source,
drift correction, and the fact that system volume is applied *before* the
signal reaches the driver.

It's also, on macOS 26 with ffmpeg's avfoundation capture, lossy. A 60-second
recording came back as a 56-second file: **~6.7% of the audio simply missing**,
audible as pops and a rushed tempo. The cause is that avfoundation timestamps
keep advancing in real time even when buffers are dropped, so ffmpeg believes
it captured 60 seconds while only 56 seconds of samples exist.

Core Audio taps sidestep the entire category. `taprec` records exactly 30
seconds for `-t 30`, with no pops and no dropouts.

The old approach is preserved in [`legacy/`](legacy/) with its diagnostics, and
[`docs/CLEANUP.md`](docs/CLEANUP.md) covers removing BlackHole if you set it up.

---

## Install

```bash
git clone https://github.com/writenorman/taprec.git
cd taprec
./taprec --install      # fetches a prebuilt AudioTee binary, no Xcode needed
./taprec --check        # verify the tap works
```

`--install` downloads a prebuilt universal binary from the `audiotee` npm
package, verifies its SHA-512 against the registry's published integrity hash,
and smoke-tests it before use. Nothing is compiled and no toolchain is required.

To put it on your `PATH`:

```bash
./install.sh            # just you  ->  ~/.local/bin
```

### For everyone on the Mac

```bash
sudo ./install.sh --system
```

That installs `taprec` into `/usr/local/bin` — already on every user's `PATH`
via `/etc/paths` — and copies the AudioTee binary to
`/usr/local/libexec/taprec/audiotee`, which `taprec` finds relative to its own
location. Without that copy every user would have to run `taprec --install`
separately in their own home.

Two things a system install still can't do on other users' behalf:

- **Audio permission is per-user.** macOS grants it to the terminal
  application, one user at a time. Everyone who wants to record has to approve
  their own terminal once — see [Permissions](#permissions). `taprec --check`
  reports whether the current user is set up.
- **Homebrew's `ffmpeg` may not be on their `PATH`.** Homebrew is added to
  `PATH` by *your* shell profile, not system-wide. To fix that for everyone:

  ```bash
  echo /opt/homebrew/bin | sudo tee /etc/paths.d/homebrew
  ```

`./install.sh --uninstall` (with the same `--system` or `--prefix`) removes
what it installed. Your AudioTee install and your recordings are left alone.

### Stereo

The prebuilt binary is **mono only** — it predates AudioTee's `--stereo` flag,
and no published npm version includes it. For stereo, build from source:

```bash
./taprec --toolchain            # are Swift ≥5.9 and macOS SDK ≥14.2 available?
./taprec --install --from-source
./taprec --check                # should now report 2 ch
```

You need Swift ≥ 5.9 **and** the macOS SDK ≥ 14.2. The SDK is the real
constraint — the taps API doesn't exist in older ones, so editing the package
manifest won't help.

You do **not** need full Xcode. Current Command Line Tools are enough (~1–2 GB,
from [developer.apple.com/download/all](https://developer.apple.com/download/all/)).
If your `xcode-select` points at an older Xcode, `taprec` detects that, finds
the newer Command Line Tools, and builds against them via `DEVELOPER_DIR` for
that one command — your global toolchain is left alone.

`--install` without `--from-source` restores the prebuilt binary at any time.
The previous binary is kept as `audiotee.prebuilt` before any source build
replaces it.

---

## Permissions

**This is the most common reason recordings come out silent.**

macOS grants audio capture to the **terminal application**, never to a script or
a binary. On macOS 26, plain executables don't appear in the privacy UI at all
(Apple has acknowledged this as a regression), so looking for `taprec` in that
list will always fail.

```
System Settings → Privacy & Security → Screen & System Audio Recording
  → "System Audio Recording Only"   ← a separate list, below the main one
  → enable Terminal / iTerm / Visual Studio Code — whichever you run this in
```

Apps only appear there once they've *requested* the permission. Terminal.app
prompts reliably; **iTerm and the VS Code terminal often don't** — they start
recording silence with no error. If yours isn't listed, run `taprec --check`
once from Terminal.app to trigger the prompt, or add the app with the `+`
button.

Permission is per-app: granting Terminal.app does nothing for iTerm.

---

## Usage

```
taprec [options]

  -t, --duration SECS   stop after SECS seconds (default: until Ctrl-C)
  -o, --output FILE     write to FILE
  -d, --dir DIR         directory for auto-named files (default: ./recordings)
  -f, --format FMT      wav | m4a | mp3 | flac
  -r, --rate HZ         8000 … 48000
      --stereo/--mono   channel count (stereo default; needs a source build)
      --open            reveal the finished file in Finder

      --only-pid PID    capture only this process (repeatable)
      --skip-pid PID    capture everything except this process (repeatable)
      --mute            silence the tapped apps while recording

      --install         install AudioTee
      --check           verify the tap and report its format
      --toolchain       report Swift/SDK versions and stereo readiness
```

Ctrl-C stops a recording and finalizes the file properly.

### Config file

`~/.config/taprec/config`:

```sh
FORMAT=m4a
SAMPLE_RATE=48000
OUT_DIR=~/Recordings
STEREO=1
```

Environment variables override the file; flags override everything.

---

## Verifying a recording

`tools/verify-recording.sh` measures a recording against the file that produced
it, and reports whether they drift apart:

```bash
tools/verify-recording.sh -s original.mp3 -r recordings/system-audio-....wav
```

It aligns the two in successive windows and watches the offset. Flat offset
means the capture kept up; a climbing offset means audio was dropped, and the
growth *is* the lost content. This is how the BlackHole loss was pinned down.

Immune to when recording started or stopped and to silence at either end. Uses
three spectral bands rather than loudness alone, so it works on compressed
material where the loudness envelope is nearly flat.

---

## How it works

```
apps → CoreAudio → [process tap] → AudioTee → raw PCM → ffmpeg → file
                        ↓
                   speakers (untouched)
```

`taprec` asks the AudioTee binary what it supports (`--help`) and what it
actually emits (its metadata message), then configures ffmpeg from those answers
rather than assuming. Different AudioTee builds differ in both — the prebuilt
has no `--stereo` and tags its JSON with `message_type` where current source
uses `type`. Probing rather than assuming keeps one script working against both.

The channel count matters more than it looks: telling ffmpeg two channels when
the stream is mono misreads every frame and produces a file at double speed.

---

## Troubleshooting

**Recording is silent** → permissions. See above. `taprec --check` distinguishes
a permission failure from a real error.

**`--check` reports 1 ch** → expected on the prebuilt binary. See Stereo.

**"could not read the tap's format"** → non-fatal; it falls back to the format
the flags guarantee. The recording is still correct.

**Wrong speed / wrong duration** → `taprec` compares the tap's reported format
against what ffmpeg was told and warns on a mismatch. Re-run with the `-r` and
`--mono`/`--stereo` it suggests.

**macOS < 14.2** → Core Audio taps don't exist. Use `legacy/blackhole-record.sh`,
with the caveats in this README.

---

## Layout

```
taprec              the recorder
install.sh          installer — per-user, or --system for everyone
tools/
  verify-recording.sh   measure a recording against its source
  diagnose-audio.sh     tone-based capture diagnostics
  compare-capture.sh    A/B capture configurations
legacy/
  blackhole-record.sh   the BlackHole/Multi-Output recorder (superseded)
docs/
  CLEANUP.md            removing BlackHole and friends
```

---

## License

MIT — see [LICENSE](LICENSE).

AudioTee is MIT-licensed too, and is fetched at install time into your own
home directory rather than bundled here. `ffmpeg` is a runtime dependency,
invoked as a separate process and not redistributed.

---

## Credits

Built on [AudioTee](https://github.com/makeusabrew/audiotee) by Nick Payne,
which does the actual Core Audio tap work. `taprec` is a wrapper around it plus
ffmpeg.
