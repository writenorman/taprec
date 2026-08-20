# Changelog

## Unreleased

- `install.sh` — installs to `~/.local/bin` for one user, or
  `sudo ./install.sh --system` to `/usr/local/bin` for everyone on the machine.
  A shared install also copies the AudioTee binary to
  `<prefix>/libexec/taprec/`, so other users don't each need `taprec --install`.
  `--uninstall` reverses it; `--prefix` targets somewhere else.
- `find_audiotee` now also looks in `../libexec/taprec/` relative to the
  running script, and in `/usr/local/libexec/taprec/`. A per-user AudioTee
  still takes precedence over the shared copy.

## 1.0.0

First release.

- Record macOS system audio via Core Audio taps — no virtual driver, no
  aggregate device, no output switching.
- `--install` fetches a checksum-verified prebuilt AudioTee binary; no Xcode or
  Swift toolchain required.
- `--install --from-source` builds current AudioTee for stereo, using newer
  Command Line Tools via `DEVELOPER_DIR` when the selected Xcode is too old, so
  the global `xcode-select` is never modified. The previous binary is preserved
  and a build that fails to run is rejected rather than installed.
- Runtime capability and format probing: reads the binary's `--help` for
  supported flags and its metadata message for the real sample rate, channel
  count and encoding. Works against both the prebuilt and current-source builds,
  which differ in flags and in JSON key naming.
- Post-recording cross-check warns if the tap's format and the decode
  parameters disagree — the failure mode that produces double-speed files.
- `--check` verifies the tap and distinguishes a permission failure from a real
  error. `--toolchain` reports Swift/SDK versions and stereo build readiness.
- Config file at `~/.config/taprec/config`.
- `tools/verify-recording.sh` measures a recording against its source file for
  content loss.
