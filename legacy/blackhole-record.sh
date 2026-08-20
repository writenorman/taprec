#!/usr/bin/env bash
#
# record-system-audio.sh — record macOS system audio output to a file.
#
# macOS won't let you record speaker output directly, so we route it through
# BlackHole (a virtual audio driver). A "Multi-Output Device" sends the same
# signal to BlackHole *and* your real speakers, so you still hear everything
# while ffmpeg records the BlackHole side.
#
# This script uses the `macos-audio` CLI to save your current output device,
# switch to the Multi-Output Device, and switch back when recording stops —
# including on Ctrl-C or if something errors out.
#
# Run `./record-system-audio.sh --setup` for one-time install instructions.
#
set -euo pipefail

# ---------------------------------------------------------------- defaults ---

BLACKHOLE_NAME="BlackHole 2ch"
MULTI_OUT_NAME="Multi-Output Device"
OUT_DIR="./recordings"
OUT_FILE=""
FORMAT="wav"
DURATION=""
MONITOR=1
RESYNC=0
SAMPLE_RATE="48000"
CHANNELS="2"

ORIGINAL_OUTPUT=""
SWITCHED=0
PROGRESS_FILE=""

# ------------------------------------------------------------------- utils ---

c_red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
c_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
c_dim() { printf '\033[2m%s\033[0m\n' "$*"; }

die() { c_red "error: $*"; exit 1; }

usage() {
  cat <<'EOF'
record-system-audio.sh — record macOS system audio output to a file

USAGE
  ./record-system-audio.sh [options]

OPTIONS
  -o, --output FILE     write to FILE (default: ./recordings/system-audio-<timestamp>.<fmt>)
  -d, --dir DIR         directory for auto-named recordings (default: ./recordings)
  -f, --format FMT      wav | m4a | mp3 | flac (default: wav)
  -t, --duration SECS   stop automatically after SECS seconds
  -r, --rate HZ         output sample rate (default: 48000)
  -c, --channels N      output channel count (default: 2)
  -m, --multi-out NAME  Multi-Output Device name (default: "Multi-Output Device")
  -b, --blackhole NAME  BlackHole device name (default: "BlackHole 2ch")
      --no-monitor      record without hearing playback (skips the Multi-Output Device)
      --resync          pad dropped buffers with silence so the recording keeps
                        correct duration and pitch instead of playing fast
      --list            show detected audio devices and exit
      --setup           run the staged setup check and tell you the next step
      --restart-coreaudio
                        reload CoreAudio (needs sudo) so a freshly installed
                        BlackHole driver becomes visible
  -h, --help            show this help

EXAMPLES
  ./record-system-audio.sh                    # record until Ctrl-C
  ./record-system-audio.sh -o talk.m4a -f m4a # explicit file, AAC encoding
  ./record-system-audio.sh -t 300             # record exactly 5 minutes

STOPPING
  Press Ctrl-C (or "q") to stop. The file is finalized and your original
  output device is restored automatically.
EOF
  exit 0
}

# --------------------------------------------------------------- arg parse ---

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)    OUT_FILE="${2:-}";        shift 2 ;;
    -d|--dir)       OUT_DIR="${2:-}";         shift 2 ;;
    -f|--format)    FORMAT="${2:-}";          shift 2 ;;
    -t|--duration)  DURATION="${2:-}";        shift 2 ;;
    -r|--rate)      SAMPLE_RATE="${2:-}";     shift 2 ;;
    -c|--channels)  CHANNELS="${2:-}";        shift 2 ;;
    -m|--multi-out) MULTI_OUT_NAME="${2:-}";  shift 2 ;;
    -b|--blackhole) BLACKHOLE_NAME="${2:-}";  shift 2 ;;
    --no-monitor)   MONITOR=0;                shift ;;
    --resync)       RESYNC=1;                 shift ;;
    --list)         DO_LIST=1;                shift ;;
    --setup)        DO_SETUP=1;               shift ;;
    --restart-coreaudio) DO_KICK=1;           shift ;;
    -h|--help)      usage ;;
    *)              die "unknown option: $1 (try --help)" ;;
  esac
done

# -------------------------------------------------------- dependency check ---

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found — install with: $2"
}

check_deps() {
  [[ "$(uname -s)" == "Darwin" ]] || die "this script only works on macOS"
  require_cmd ffmpeg "brew install ffmpeg"
  require_cmd SwitchAudioSource "brew install switchaudio-osx"
  if ! command -v macos-audio >/dev/null 2>&1; then
    c_ylw "note: macos-audio CLI not found — using SwitchAudioSource directly."
    c_dim "      install it with: brew install vossenwout/tap/macos-audio-cli"
  fi
}

# ----------------------------------------------------------- device lookup ---

# All CoreAudio output devices, one per line.
list_outputs() {
  SwitchAudioSource -a -t output
}

device_exists() {
  list_outputs | grep -Fxq "$1"
}

# Is the BlackHole driver bundle actually on disk? Installed and *loaded* are
# two different things — CoreAudio only scans HAL plug-ins when it starts, so a
# fresh install stays invisible until coreaudiod is restarted.
blackhole_driver_installed() {
  # Plain glob rather than `compgen -G`: macOS still ships bash 3.2 as /bin/bash
  # and this works identically there.
  local d
  for d in /Library/Audio/Plug-Ins/HAL/BlackHole*.driver; do
    [[ -e "$d" ]] && return 0
  done
  return 1
}

restart_coreaudio() {
  c_ylw "restarting CoreAudio — you'll be asked for your password."
  c_dim "audio will cut out for a second or two."
  if sudo launchctl kickstart -k system/com.apple.audio.coreaudiod; then
    sleep 2
    c_grn "CoreAudio reloaded."
    return 0
  fi
  c_red "could not restart CoreAudio; a reboot will also do it."
  return 1
}

# Parse `ffmpeg -f avfoundation -list_devices true` and emit "index<TAB>name"
# for audio devices only. ffmpeg writes this to stderr and exits non-zero.
# Uses POSIX awk only (macOS ships BSD awk, not gawk).
list_avf_audio_devices() {
  # ffmpeg always exits non-zero for -list_devices; `|| true` keeps `set -o
  # pipefail` from treating that as a failure of the whole function.
  { ffmpeg -f avfoundation -list_devices true -i "" -hide_banner 2>&1 </dev/null || true; } | awk '
    /AVFoundation video devices:/ { in_audio = 0; next }
    /AVFoundation audio devices:/ { in_audio = 1; next }
    in_audio {
      line = $0
      sub(/^\[[^]]*@[^]]*\][ \t]*/, "", line)   # strip "[avfoundation @ 0x..] "
      if (match(line, /^\[[0-9]+\]/)) {
        idx  = substr(line, RSTART + 1, RLENGTH - 2)
        name = substr(line, RSTART + RLENGTH)
        sub(/^[ \t]+/, "", name)
        sub(/[ \t\r]+$/, "", name)
        print idx "\t" name
      }
    }
  '
}

# Find the avfoundation audio index for a device name: exact match first, then
# case-insensitive substring.
find_avf_index() {
  local want="$1" devices idx name
  devices="$(list_avf_audio_devices)"
  [[ -n "$devices" ]] || return 1

  while IFS=$'\t' read -r idx name; do
    [[ "$name" == "$want" ]] && { printf '%s' "$idx"; return 0; }
  done <<< "$devices"

  while IFS=$'\t' read -r idx name; do
    if printf '%s' "$name" | grep -iqF -- "$want"; then
      printf '%s' "$idx"
      return 0
    fi
  done <<< "$devices"

  return 1
}

# ------------------------------------------------------ output device swap ---

get_output_device() {
  if command -v macos-audio >/dev/null 2>&1; then
    macos-audio status --json 2>/dev/null \
      | sed -n 's/.*"output"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n1
  else
    SwitchAudioSource -c -t output 2>/dev/null
  fi
}

set_output_device() {
  local name="$1"
  if command -v macos-audio >/dev/null 2>&1; then
    macos-audio connect local "$name" >/dev/null 2>&1 && return 0
  fi
  SwitchAudioSource -s "$name" -t output >/dev/null
}

restore_output() {
  if [[ "$SWITCHED" -eq 1 && -n "$ORIGINAL_OUTPUT" ]]; then
    SWITCHED=0
    c_dim "restoring output device → $ORIGINAL_OUTPUT"
    set_output_device "$ORIGINAL_OUTPUT" || \
      c_red "could not restore output to '$ORIGINAL_OUTPUT' — set it manually in System Settings › Sound"
  fi
}

# Restore routing no matter how we exit. On Ctrl-C, bash defers this trap until
# the foreground ffmpeg has caught SIGINT and finalized the file.
#
# The progress file is only removed on EXIT, never on INT — the Ctrl-C handler
# must leave it intact so the speed check below can still read it.
trap restore_output INT TERM
# The `true` is load-bearing: an EXIT trap ending in a false short-circuit
# replaces the script's exit status with 1.
trap 'restore_output; if [[ -n "${PROGRESS_FILE:-}" ]]; then rm -f "$PROGRESS_FILE"; fi; true' EXIT

# Report whether the capture clock actually kept up with wall-clock time.
#
# For a live capture ffmpeg's `speed` is (media time produced / wall time),
# which equals (real delivery rate / the rate ffmpeg believes the device runs
# at). Below 1.0 means fewer samples arrived than the declared rate implies, so
# on playback they get played too quickly: playback error = 1/speed.
check_capture_speed() {
  [[ -n "${PROGRESS_FILE:-}" && -s "${PROGRESS_FILE:-}" ]] || return 0

  local speed err mag
  speed="$(sed -n 's/^speed=[[:space:]]*\([0-9.][0-9.]*\)x*[[:space:]]*$/\1/p' "$PROGRESS_FILE" | tail -n1)"
  [[ -n "$speed" ]] || return 0   # ffmpeg prints speed=N/A before the first frames

  err="$(awk -v s="$speed" 'BEGIN { if (s + 0 <= 0) { print "skip"; exit } printf "%.2f", (1 / s - 1) * 100 }')"
  [[ "$err" == "skip" ]] && return 0
  mag="$(awk -v e="$err" 'BEGIN { printf "%.2f", (e < 0 ? -e : e) }')"

  echo
  if awk -v m="$mag" 'BEGIN { exit !(m < 0.5) }'; then
    c_dim "  capture clock ${speed}x — playback speed within tolerance (${err}%)."
    return 0
  fi

  if awk -v e="$err" 'BEGIN { exit !(e > 0) }'; then
    c_ylw "  ⚠ capture clock ran at ${speed}x — this file plays back ${err}% TOO FAST."
  else
    c_ylw "  ⚠ capture clock ran at ${speed}x — this file plays back ${err}% too slow."
  fi

  # A ratio near 44100/48000 (or its inverse) is a nominal rate mismatch; a
  # fraction of a percent is clock drift. They have different fixes.
  if awk -v s="$speed" 'BEGIN { exit !(s > 0.90 && s < 0.94) }'; then
    c_dim "    ratio ≈ 44100/48000: the device is really at 44.1 kHz but is being read as 48 kHz."
    c_dim "    Set BlackHole and your speakers to the SAME rate in Audio MIDI Setup."
  elif awk -v s="$speed" 'BEGIN { exit !(s > 1.06 && s < 1.10) }'; then
    c_dim "    ratio ≈ 48000/44100: the rates are mismatched the other way round."
    c_dim "    Set BlackHole and your speakers to the SAME rate in Audio MIDI Setup."
  elif awk -v m="$mag" 'BEGIN { exit !(m <= 2.0) }'; then
    c_dim "    Under 2% is clock drift, not a rate mismatch. Check that BlackHole's"
    c_dim "    Clock Source is 'Internal Fixed' (an off-centre Balance slider on"
    c_dim "    'Internal Adjustable' produces exactly this), and that Drift Correction"
    c_dim "    is ON for BlackHole and OFF for the primary device."
  fi
  c_dim "    Run ./diagnose-audio.sh to measure it precisely."
}

# ---------------------------------------------------------- kick coreaudio ---

if [[ -n "${DO_KICK:-}" ]]; then
  restart_coreaudio || exit 1
  if device_exists "$BLACKHOLE_NAME"; then
    c_grn "'$BLACKHOLE_NAME' is now visible to CoreAudio."
  else
    c_ylw "'$BLACKHOLE_NAME' is still not visible. Run '$0 --setup' to see which step is missing."
  fi
  exit 0
fi

# ------------------------------------------------------------------ setup ----

# Staged preflight. Each stage checks one thing and, if it fails, prints only
# the fix for THAT stage and stops. No point opening Audio MIDI Setup to look
# for a device whose driver has not loaded yet.
if [[ -n "${DO_SETUP:-}" ]]; then
  [[ "$(uname -s)" == "Darwin" ]] || die "this script only works on macOS"
  echo "Setup check for recording macOS system audio"
  echo "============================================"
  echo

  # --- stage 1: command-line tools -------------------------------------------
  missing=()
  command -v ffmpeg            >/dev/null 2>&1 || missing+=("ffmpeg|brew install ffmpeg")
  command -v SwitchAudioSource >/dev/null 2>&1 || missing+=("SwitchAudioSource|brew install switchaudio-osx")
  command -v macos-audio       >/dev/null 2>&1 || missing+=("macos-audio|brew install vossenwout/tap/macos-audio-cli")

  if [[ ${#missing[@]} -gt 0 ]]; then
    c_red "✗ 1. Missing command-line tools."
    echo
    for entry in "${missing[@]}"; do
      echo "     ${entry%%|*} — install with: ${entry##*|}"
    done
    echo
    c_dim "   Re-run '$0 --setup' once those are installed."
    exit 1
  fi
  c_grn "✔ 1. Command-line tools installed (ffmpeg, SwitchAudioSource, macos-audio)."

  # --- stage 2: BlackHole driver on disk -------------------------------------
  if ! blackhole_driver_installed; then
    c_red "✗ 2. BlackHole driver is not installed."
    cat <<'EOF'

     Install it:

       brew install --cask blackhole-2ch

     The installer needs your password. If you dismissed the password prompt
     the cask silently does nothing, so re-run it and watch for the prompt.
     macOS may also hold the driver in System Settings › Privacy & Security
     behind an "Allow" button — approve it there if you see one.

EOF
    c_dim "   Then re-run '$0 --setup'."
    exit 1
  fi
  c_grn "✔ 2. BlackHole driver present in /Library/Audio/Plug-Ins/HAL."

  # --- stage 3: CoreAudio has actually loaded it -----------------------------
  # This is the stage that trips people up: the driver is on disk but CoreAudio
  # only scans HAL plug-ins at daemon start, so it stays invisible until
  # coreaudiod is restarted (or you reboot).
  if ! device_exists "$BLACKHOLE_NAME"; then
    c_red "✗ 3. '$BLACKHOLE_NAME' is installed but CoreAudio has not loaded it."
    cat <<EOF

     The driver is on disk, so this is not an install problem. CoreAudio only
     scans HAL plug-ins when the daemon starts, so a fresh install stays
     invisible until you reload it:

       $0 --restart-coreaudio

     or directly:

       sudo launchctl kickstart -k system/com.apple.audio.coreaudiod

     Audio cuts out for a second or two. A reboot does the same thing.

EOF
    c_dim "   Then re-run '$0 --setup'."
    exit 1
  fi
  c_grn "✔ 3. '$BLACKHOLE_NAME' is registered with CoreAudio."

  # --- stage 4: Multi-Output Device ------------------------------------------
  if ! device_exists "$MULTI_OUT_NAME"; then
    c_ylw "✗ 4. '$MULTI_OUT_NAME' does not exist yet."
    cat <<EOF

     This is the one step with no CLI equivalent — CoreAudio only exposes
     aggregate-device creation through the GUI. Opening Audio MIDI Setup now:

       a. Click "+" in the bottom-left → "Create Multi-Output Device".
       b. Tick BOTH your real speakers/headphones AND "$BLACKHOLE_NAME".
       c. Put your real output FIRST — it becomes the clock source, which
          keeps the two devices from drifting apart.
       d. Tick "Drift Correction" on the $BLACKHOLE_NAME row, not the primary.
       e. Leave the name as "$MULTI_OUT_NAME", or pass a custom one with -m.

     Why bother? BlackHole on its own is a dead end: audio sent there goes only
     to the virtual driver, so you record fine but hear nothing. The
     Multi-Output splits the signal to both. Pass --no-monitor to skip it if
     recording in silence is fine.

EOF
    if command -v open >/dev/null 2>&1; then
      open -a "Audio MIDI Setup" 2>/dev/null || true
    fi
    c_dim "   Then re-run '$0 --setup'."
    exit 1
  fi
  c_grn "✔ 4. '$MULTI_OUT_NAME' exists."

  # --- all clear -------------------------------------------------------------
  echo
  c_grn "Setup looks complete. Try a 10-second test:"
  echo
  echo "    $0 -t 10"
  echo
  cat <<'EOF'
Two things that silently ruin recordings:

  • Microphone permission. The first time ffmpeg opens an avfoundation input,
    macOS prompts your terminal for MIC access — required even though you are
    capturing output, not a mic. If your terminal never prompts (iTerm is known
    for this), grant it manually in System Settings › Privacy & Security.

  • System volume is applied BEFORE the signal reaches BlackHole, so turning
    your Mac down turns the recording down too. Keep system output at 100% and
    use the app's own volume slider instead.
EOF
  exit 0
fi

# ------------------------------------------------------------------- list ----

if [[ -n "${DO_LIST:-}" ]]; then
  check_deps
  echo "CoreAudio output devices (SwitchAudioSource):"
  list_outputs | sed 's/^/  /'
  echo
  echo "ffmpeg avfoundation audio inputs:"
  devs="$(list_avf_audio_devices)"
  if [[ -z "$devs" ]]; then
    echo "  (none found — is ffmpeg built with avfoundation support?)"
  else
    printf '%s\n' "$devs" | awk -F'\t' '{ printf "  [%s] %s\n", $1, $2 }'
  fi
  echo
  echo "current output: $(get_output_device || echo unknown)"
  exit 0
fi

# ------------------------------------------------------------------- main ----

check_deps

case "$FORMAT" in
  wav)  codec=(-c:a pcm_s16le) ;;
  m4a)  codec=(-c:a aac -b:a 192k) ;;
  mp3)  codec=(-c:a libmp3lame -q:a 2) ;;
  flac) codec=(-c:a flac) ;;
  *)    die "unsupported format '$FORMAT' (use wav, m4a, mp3, or flac)" ;;
esac

# BlackHole must exist as a capture source.
if ! BH_INDEX="$(find_avf_index "$BLACKHOLE_NAME")"; then
  c_red "'$BLACKHOLE_NAME' is not available as an ffmpeg audio input."
  if blackhole_driver_installed; then
    c_dim "the driver IS installed — CoreAudio just has not loaded it. Fix with:"
    c_dim "    $0 --restart-coreaudio"
  else
    c_dim "the driver is not installed. Run '$0 --setup' for the steps."
  fi
  c_dim "'$0 --list' shows what is currently available."
  exit 1
fi
c_dim "capture source: [$BH_INDEX] $BLACKHOLE_NAME"

# Route system output so we can still hear it while recording.
ORIGINAL_OUTPUT="$(get_output_device || true)"
if [[ "$MONITOR" -eq 1 ]]; then
  if ! device_exists "$MULTI_OUT_NAME"; then
    c_red "output device '$MULTI_OUT_NAME' not found."
    c_dim "create it in Audio MIDI Setup — run '$0 --setup' for the steps,"
    c_dim "or pass --no-monitor to record without hearing anything."
    exit 1
  fi
  TARGET_OUTPUT="$MULTI_OUT_NAME"
else
  device_exists "$BLACKHOLE_NAME" || die "output device '$BLACKHOLE_NAME' not found — is BlackHole installed?"
  c_ylw "--no-monitor: routing output to BlackHole only. You will NOT hear anything while recording."
  TARGET_OUTPUT="$BLACKHOLE_NAME"
fi

[[ -n "$ORIGINAL_OUTPUT" ]] || c_ylw "warning: could not read the current output device; won't be able to restore it."
c_dim "current output: ${ORIGINAL_OUTPUT:-unknown} → switching to '$TARGET_OUTPUT'"
set_output_device "$TARGET_OUTPUT" || die "could not switch output to '$TARGET_OUTPUT'"
SWITCHED=1

# Resolve the destination file.
if [[ -z "$OUT_FILE" ]]; then
  mkdir -p "$OUT_DIR"
  OUT_FILE="$OUT_DIR/system-audio-$(date +%Y%m%d-%H%M%S).$FORMAT"
else
  mkdir -p "$(dirname "$OUT_FILE")"
fi

# Sample-rate and channel conversion go on the OUTPUT side — the avfoundation
# demuxer takes whatever BlackHole's format is and rejects most input options.
# -progress writes machine-readable key=value blocks to a file while -stats
# keeps the live display. We read the final `speed=` out of it afterwards: for a
# live capture that value is (media time produced / wall-clock time), which is
# the same as (actual delivery rate / the rate ffmpeg believes). Anything other
# than 1.0 means the recording will play back at the wrong speed.
# Explicit XXXXXX template: `mktemp -t prefix` means different things on BSD and
# GNU mktemp, and the bare-prefix form is an error on the latter.
PROGRESS_FILE="$(mktemp "${TMPDIR:-/tmp}/audio-progress.XXXXXX")"
ff_args=(
  -hide_banner -loglevel warning -stats
  -progress "$PROGRESS_FILE"
  -f avfoundation
  -i ":$BH_INDEX"
  -ar "$SAMPLE_RATE"
  -ac "$CHANNELS"
)
# avfoundation timestamps keep advancing in real time even when buffers are
# dropped, so ffmpeg ends up with fewer samples than the timestamps imply and the
# file plays fast. aresample=async tells it to stretch/pad the audio to match
# those timestamps: the lost audio is still lost, but it becomes brief silences
# at the right moments rather than the whole recording running ~7% quick.
if [[ "$RESYNC" -eq 1 ]]; then
  ff_args+=(-af "aresample=async=${SAMPLE_RATE}:first_pts=0")
fi
[[ -n "$DURATION" ]] && ff_args+=(-t "$DURATION")
ff_args+=("${codec[@]}" "$OUT_FILE")

echo
c_grn "▶ recording system audio → $OUT_FILE"
if [[ -n "$DURATION" ]]; then
  c_dim "  stopping automatically after ${DURATION}s (Ctrl-C or q to stop early)"
else
  c_dim "  press Ctrl-C (or q) to stop"
fi
echo

ffmpeg "${ff_args[@]}" || true
restore_output

echo
if [[ -s "$OUT_FILE" ]]; then
  size="$(du -h "$OUT_FILE" | cut -f1 | tr -d ' ')"
  dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT_FILE" 2>/dev/null | cut -d. -f1 || true)"
  c_grn "✔ saved $OUT_FILE (${size}${dur:+, ${dur}s})"
  c_dim "  play it back with: macos-audio play \"$OUT_FILE\""
  check_capture_speed
else
  c_red "recording produced an empty file — was anything actually playing?"
  c_dim "check that the Multi-Output Device includes BlackHole and that system volume is up."
  exit 1
fi
