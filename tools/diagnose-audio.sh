#!/usr/bin/env bash
#
# diagnose-audio.sh — find out WHY a BlackHole capture pops or plays at the
# wrong speed, by measuring it instead of guessing.
#
# It plays a 1 kHz tone through your Multi-Output Device while recording from
# BlackHole, then measures the captured tone. The frequency you get back tells
# you the speed error exactly, and the ratio identifies the cause:
#
#   +8.84%  -> device is really at 44100 but the capture claims 48000
#   -8.13%  -> the reverse
#   <1%     -> clock drift; the devices are not locked to one clock
#   0% but clicks -> drift correction / buffer problem, not a rate problem
#
# Usage:
#   ./diagnose-audio.sh                    # full check: rates + loopback test
#   ./diagnose-audio.sh --rates            # just report device sample rates
#   ./diagnose-audio.sh --analyze f.wav    # analyse a recording you already have
#   ./diagnose-audio.sh -s 20              # longer test tone (default 12s)
#
set -euo pipefail

BLACKHOLE_NAME="BlackHole 2ch"
MULTI_OUT_NAME="Multi-Output Device"
TONE_HZ=1000
TONE_SECONDS=12
KEEP=0
MODE="full"
ANALYZE_FILE=""
EXPECT_SECONDS=""
MONITOR=1

c_red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
c_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
c_dim() { printf '\033[2m%s\033[0m\n' "$*"; }
c_hdr() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()   { c_red "error: $*"; exit 1; }

# Sub-second wall clock. macOS ships perl; bash 3.2 has no EPOCHREALTIME.
now_seconds() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    printf '%s' "${EPOCHREALTIME/,/.}"
  elif command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%.3f", time'
  else
    date +%s
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--blackhole) BLACKHOLE_NAME="${2:-}"; shift 2 ;;
    -m|--multi-out) MULTI_OUT_NAME="${2:-}"; shift 2 ;;
    -s|--seconds)   TONE_SECONDS="${2:-}";   shift 2 ;;
    -f|--frequency) TONE_HZ="${2:-}";        shift 2 ;;
    --rates)        MODE="rates";            shift ;;
    --analyze)      MODE="analyze"; ANALYZE_FILE="${2:-}"; shift 2 ;;
    --expect-seconds) EXPECT_SECONDS="${2:-}"; shift 2 ;;
    --no-monitor)   MONITOR=0;               shift ;;
    --selftest)     MODE="selftest";         shift ;;
    --keep)         KEEP=1;                  shift ;;
    -h|--help)      sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              die "unknown option: $1" ;;
  esac
done

WORKDIR="$(mktemp -d /tmp/audio-diagnose.XXXXXX)"
ANALYZER="$WORKDIR/analyze_capture.py"
ORIGINAL_OUTPUT=""
SWITCHED=0

cleanup() {
  if [[ "$SWITCHED" -eq 1 && -n "$ORIGINAL_OUTPUT" ]]; then
    SWITCHED=0
    c_dim "restoring output device -> $ORIGINAL_OUTPUT"
    SwitchAudioSource -s "$ORIGINAL_OUTPUT" -t output >/dev/null 2>&1 || true
  fi
  if [[ "$KEEP" -eq 1 ]]; then
    c_dim "test files kept in $WORKDIR"
  else
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT INT TERM

write_analyzer() {
  cat > "$ANALYZER" <<'PYEOF'
#!/usr/bin/env python3
"""
analyze_capture.py — measure a recorded test tone for speed error and glitches.

Reads a 16-bit PCM WAV containing a recorded sine tone and reports:
  * measured frequency (via zero-crossing rate) vs the expected frequency,
    which gives the playback speed ratio
  * click/discontinuity count (sudden sample-to-sample jumps)
  * dropout count (runs of near-silence inside the tone)

Pure standard library on purpose — stock macOS python3 has no numpy, and a
diagnostic that needs its own install is a diagnostic nobody runs.

Usage: analyze_capture.py <file.wav> <expected_hz> [expected_seconds] [--json]

Passing expected_seconds enables the content-loss check, which catches the
failure mode nothing else here sees: when a device is fed faster than its clock
consumes, chunks get DROPPED rather than silenced. The stream splices back
together with no gap, so pitch is untouched and ffmpeg's speed reads 1.0x, but
material is missing — which is what "sounds fast" actually is in that case.
Only a duration comparison against a known-length source reveals it.
"""

import array
import json
import math
import statistics
import sys
import wave


def load_mono(path):
    """Return (samples as list of int, framerate). Mixes stereo down to mono."""
    with wave.open(path, "rb") as w:
        n_channels = w.getnchannels()
        width = w.getsampwidth()
        rate = w.getframerate()
        n_frames = w.getnframes()
        raw = w.readframes(n_frames)

    if width != 2:
        raise SystemExit(f"expected 16-bit PCM, got {width * 8}-bit")

    samples = array.array("h")
    samples.frombytes(raw)
    if sys.byteorder == "big":
        samples.byteswap()

    if n_channels > 1:
        mono = [
            sum(samples[i : i + n_channels]) // n_channels
            for i in range(0, len(samples) - n_channels + 1, n_channels)
        ]
    else:
        mono = list(samples)

    return mono, rate


def find_tone_region(samples, rate):
    """Trim leading/trailing silence so padding doesn't skew the measurement."""
    if not samples:
        return 0, 0

    window = max(1, rate // 100)  # 10 ms

    def window_rms(idx):
        chunk = samples[idx : idx + window]
        if not chunk:
            return 0.0
        return (sum(s * s for s in chunk) / len(chunk)) ** 0.5

    # Threshold off the loudest *window* RMS, not the loudest sample. A single
    # click sample is diluted by the window, so an impulsive glitch can't drag
    # the threshold above the tone itself and hide the whole region.
    rms_values = [window_rms(i) for i in range(0, len(samples), window)]
    reference = max(rms_values) if rms_values else 0.0
    if reference <= 0:
        return 0, 0
    threshold = reference * 0.25

    def loud(idx):
        return window_rms(idx) > threshold

    start = 0
    while start < len(samples) and not loud(start):
        start += window
    end = len(samples) - window
    while end > start and not loud(end):
        end -= window

    return start, max(start, end + window)


def measure_frequency(samples, rate):
    """
    Estimate frequency from the zero-crossing rate.

    For a clean sine this is accurate to well under 0.1%, which is far tighter
    than the errors we're hunting (0.5% drift up to 8.8% rate mismatch), and it
    needs no FFT.
    """
    if len(samples) < 2:
        return 0.0

    # Remove DC offset — a biased signal shifts crossings and skews the estimate.
    mean = sum(samples) / len(samples)

    crossings = 0
    first = None
    last = None
    prev = samples[0] - mean
    for i in range(1, len(samples)):
        cur = samples[i] - mean
        if (prev < 0 <= cur) or (prev > 0 >= cur):
            crossings += 1
            if first is None:
                first = i
            last = i
        prev = cur

    if crossings < 2 or first is None or last is None or last == first:
        return 0.0

    # Measure between first and last crossing only: partial cycles at the edges
    # would otherwise bias the result.
    span_seconds = (last - first) / rate
    # Two zero crossings per cycle.
    return (crossings - 1) / 2.0 / span_seconds


def count_cycles(samples, rate):
    """
    Count complete cycles of the tone using a Schmitt trigger.

    This is the one content measurement that owes nothing to timing. A 12 s
    1 kHz tone contains exactly 12000 cycles no matter when capture started or
    stopped, how long the device took to open, or how much silence pads either
    end. Cycles that are missing were genuinely dropped.

    Every duration-based metric I tried before this leaked process lifecycle
    (device-open latency, WAV finalize) into the result and reported it as lost
    audio. Counting the signal's own periods cannot do that.

    Hysteresis at +/-25% of peak stops noise and small glitches near the zero
    crossing from being counted as extra cycles.
    """
    if len(samples) < 2:
        return 0

    peak = max(abs(s) for s in samples)
    if peak == 0:
        return 0

    hi = peak * 0.25
    lo = -hi

    cycles = 0
    state = 0  # -1 below lo, +1 above hi, 0 in between
    for s in samples:
        if s > hi:
            if state == -1:
                cycles += 1
            state = 1
        elif s < lo:
            state = -1

    return cycles


def detect_clicks(samples, rate):
    """
    Count discontinuities. A click is a sample-to-sample jump far larger than
    the signal's typical slew rate. Adjacent offending samples are collapsed
    into a single event so one pop isn't counted several times.
    """
    if len(samples) < 3:
        return 0, []

    diffs = [abs(samples[i] - samples[i - 1]) for i in range(1, len(samples))]
    if not diffs:
        return 0, []

    # Compare against the signal's own near-maximum slew rate (p99), not the
    # median. A sine's max slew is only ~1.6x its median, so a median-based
    # threshold has to be set so high it misses the abrupt level jumps that
    # buffer underruns produce. p99 tracks legitimate slew closely and is still
    # immune to the handful of outliers we're trying to find.
    ordered = sorted(diffs[:: max(1, len(diffs) // 200000)])
    p99 = ordered[int(len(ordered) * 0.99)] if ordered else 0
    rms = (sum(s * s for s in samples) / len(samples)) ** 0.5

    # The rms guard keeps a near-silent recording from reporting dither as clicks.
    threshold = max(p99 * 4, rms * 0.5, 1)

    events = []
    i = 0
    min_gap = max(1, rate // 1000)  # collapse within 1 ms
    while i < len(diffs):
        if diffs[i] > threshold:
            events.append(i / rate)
            i += min_gap
        else:
            i += 1

    return len(events), events[:20]


def detect_dropouts(samples, rate):
    """Count runs of near-silence >= 5 ms inside the tone region."""
    if not samples:
        return 0, []

    peak = max(abs(s) for s in samples) or 1
    floor = peak * 0.02
    # 2 ms: short enough to catch a single dropped buffer, long enough that a
    # sine's own zero crossings (microseconds) never register.
    min_run = max(1, (rate * 2) // 1000)

    dropouts = []
    run_start = None
    for i, s in enumerate(samples):
        if abs(s) < floor:
            if run_start is None:
                run_start = i
        else:
            if run_start is not None and i - run_start >= min_run:
                dropouts.append((run_start / rate, (i - run_start) / rate))
            run_start = None
    if run_start is not None and len(samples) - run_start >= min_run:
        dropouts.append((run_start / rate, (len(samples) - run_start) / rate))

    return len(dropouts), dropouts[:20]


COMMON_RATES = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000]


def explain_ratio(ratio, file_rate):
    """Map a speed ratio onto the most likely device-configuration cause."""
    if ratio <= 0:
        return "no tone detected", None

    pct = (ratio - 1.0) * 100.0

    if abs(pct) < 0.15:
        return "clock is correct", None

    # A rate mismatch shows up as a ratio between two standard rates. The file
    # says `file_rate`; the true capture rate would be file_rate / ratio.
    implied = file_rate / ratio
    best = min(COMMON_RATES, key=lambda r: abs(r - implied))
    # `best == file_rate` means the implied rate rounded back to the rate we
    # already have — that is drift, not a mismatch, and reporting it as
    # "48000 written as 48000" would be gibberish.
    if best != file_rate and abs(best - implied) / best < 0.02:
        return (
            f"sample-rate mismatch: audio was really at {best} Hz "
            f"but got written as {file_rate} Hz"
        ), best

    if abs(pct) < 2.0:
        return "small clock drift (devices not locked to one clock)", None

    return "non-standard rate mismatch", None


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    as_json = "--json" in sys.argv[1:]

    if len(args) < 2:
        raise SystemExit(
            "usage: analyze_capture.py <file.wav> <expected_hz> [expected_seconds] [--json]"
        )

    path = args[0]
    expected_hz = float(args[1])
    expected_seconds = float(args[2]) if len(args) > 2 else None

    samples, rate = load_mono(path)
    if not samples:
        raise SystemExit("file contains no audio")

    start, end = find_tone_region(samples, rate)
    region = samples[start:end]
    if len(region) < rate // 10:
        raise SystemExit(
            "could not find a tone in the recording — was anything actually captured?"
        )

    measured_hz = measure_frequency(region, rate)
    ratio = measured_hz / expected_hz if expected_hz else 0.0
    clicks, click_times = detect_clicks(region, rate)
    dropouts, dropout_spans = detect_dropouts(region, rate)
    verdict, implied_rate = explain_ratio(ratio, rate)

    peak = max(abs(s) for s in region)
    peak_dbfs = float("-inf") if peak == 0 else 20 * math.log10(peak / 32768.0)

    tone_seconds = len(region) / rate

    # Cycle count is the authoritative content measure — immune to capture
    # window, device-open latency and padding. Duration is kept only as a
    # secondary readout.
    cycles_measured = count_cycles(region, rate)
    cycles_expected = None
    content_loss_pct = None
    duration_loss_pct = None

    if expected_seconds and expected_seconds > 0:
        cycles_expected = expected_hz * expected_seconds
        duration_loss_pct = (expected_seconds - tone_seconds) / expected_seconds * 100.0
        content_loss_pct = (
            (cycles_expected - cycles_measured) / cycles_expected * 100.0
            if cycles_expected
            else None
        )
        # Pitch intact but material missing => dropped buffers, and that
        # outranks any small speed reading because it IS the fault.
        #
        # The tolerance is 0.5%, not a tight 0.15%: splices themselves perturb
        # the zero-crossing estimate (measured at ~0.05% per 19 drops), so a
        # heavily spliced capture shows a small phantom speed error. Ranking a
        # sub-0.5% reading above multi-percent content loss would point at drift
        # when the real fault is dropped buffers.
        # Rank the two effects RELATIVE to each other rather than against a fixed
        # cutoff. Splicing perturbs the zero-crossing estimate roughly in
        # proportion to how much was spliced (measured: ~0.05% at 19 drops,
        # ~0.15% at 48), so a heavily dropped capture always shows a phantom
        # speed error. Two fixed thresholds (0.15%, then 0.5%) both misfired,
        # headlining sub-1% drift over double-digit content loss. If the loss
        # dwarfs the speed reading, the loss is the story.
        speed_err_pct = abs(ratio - 1.0) * 100.0
        if (
            content_loss_pct is not None
            and content_loss_pct > 2.0
            and speed_err_pct < content_loss_pct / 4.0
        ):
            verdict = (
                f"dropped audio: pitch is correct but {content_loss_pct:.1f}% of the "
                f"content is missing (buffers being dropped, not a clock error)"
            )

    result = {
        "file": path,
        "file_sample_rate": rate,
        "tone_seconds": round(tone_seconds, 3),
        "expected_seconds": expected_seconds,
        "content_loss_pct": None if content_loss_pct is None else round(content_loss_pct, 2),
        "duration_loss_pct": None if duration_loss_pct is None else round(duration_loss_pct, 2),
        "cycles_measured": cycles_measured,
        "cycles_expected": None if cycles_expected is None else int(cycles_expected),
        "expected_hz": expected_hz,
        "measured_hz": round(measured_hz, 2),
        "speed_ratio": round(ratio, 5),
        "speed_error_pct": round((ratio - 1.0) * 100.0, 3),
        "verdict": verdict,
        "implied_true_rate": implied_rate,
        "clicks": clicks,
        "click_times": [round(t, 3) for t in click_times],
        "dropouts": dropouts,
        "dropout_spans": [(round(a, 3), round(b, 3)) for a, b in dropout_spans],
        "peak_dbfs": round(peak_dbfs, 1),
    }

    if as_json:
        print(json.dumps(result, indent=2))
        return

    print(f"  file sample rate : {rate} Hz")
    print(f"  tone found       : {result['tone_seconds']} s, peak {result['peak_dbfs']} dBFS")
    print(f"  expected tone    : {expected_hz:.1f} Hz")
    print(f"  measured tone    : {measured_hz:.1f} Hz")
    print(f"  speed error      : {result['speed_error_pct']:+.3f}%")
    if content_loss_pct is not None:
        print(f"  expected length  : {expected_seconds:.2f} s")
        print(f"  cycles expected  : {int(cycles_expected)}")
        print(f"  cycles captured  : {cycles_measured}")
        print(f"  content missing  : {content_loss_pct:+.2f}%   (from cycle count)")
        print(f"  duration short   : {duration_loss_pct:+.2f}%   (secondary, timing-sensitive)")
    print(f"  clicks/pops      : {clicks}")
    print(f"  dropouts         : {dropouts}")


if __name__ == "__main__":
    main()
PYEOF
}

# ------------------------------------------------------------- device rates ---

# Pull each audio device's current sample rate out of system_profiler. The
# device name is the last bare "Something:" header before each SampleRate line.
SP_DUMP=""
load_sp_dump() {
  [[ -n "$SP_DUMP" ]] && return 0
  SP_DUMP="$(system_profiler SPAudioDataType 2>/dev/null || true)"
}

report_rates() {
  c_hdr "Device sample rates"
  local out
  load_sp_dump
  out="$SP_DUMP"
  if [[ -z "$out" ]]; then
    c_ylw "  (system_profiler returned nothing)"
    return 0
  fi

  printf '%s\n' "$out" | awk '
    /^[[:space:]]*[A-Za-z0-9][^:]*:[[:space:]]*$/ {
      name = $0
      gsub(/^[[:space:]]+/, "", name)
      sub(/:[[:space:]]*$/, "", name)
      next
    }
    /Current SampleRate:/ {
      rate = $0
      sub(/.*Current SampleRate:[[:space:]]*/, "", rate)
      gsub(/[[:space:]]/, "", rate)
      if (name != "") printf "  %-34s %s Hz\n", name, rate
    }
  '

  # Only the devices actually in the capture path matter. Comparing every device
  # in the system flags iPhone mics and idle headsets that are not involved,
  # which is a false alarm that sends you rewriting settings for no reason.
  local bh mo dflt current
  bh="$(rate_for_device "$out" "$BLACKHOLE_NAME")"
  mo="$(rate_for_device "$out" "$MULTI_OUT_NAME")"
  current="$(SwitchAudioSource -c -t output 2>/dev/null || true)"
  [[ -n "$current" ]] && dflt="$(rate_for_device "$out" "$current")"

  echo
  local relevant=""
  [[ -n "$bh"   ]] && relevant+="$bh\n"
  [[ -n "$mo"   ]] && relevant+="$mo\n"
  [[ -n "$dflt" ]] && relevant+="$dflt\n"
  local uniq count
  uniq="$(printf "%b" "$relevant" | grep -c . >/dev/null 2>&1 && printf "%b" "$relevant" | sort -u | grep . || true)"
  count="$(printf '%s\n' "$uniq" | grep -c . || true)"

  if [[ "$count" -gt 1 ]]; then
    c_red "  ! Capture-path devices disagree on sample rate:"
    [[ -n "$bh"   ]] && c_red "      $BLACKHOLE_NAME: ${bh} Hz"
    [[ -n "$mo"   ]] && c_red "      $MULTI_OUT_NAME: ${mo} Hz"
    [[ -n "$dflt" ]] && c_red "      ${current}: ${dflt} Hz"
    c_dim "    Set these to the same rate in Audio MIDI Setup."
  elif [[ "$count" -eq 1 ]]; then
    c_grn "  Capture-path devices all agree at ${uniq} Hz."
    c_dim "  (Other devices listed above may differ — they are not in the path.)"
  else
    c_ylw "  Could not read rates for the capture-path devices."
  fi
}

# Pull one named device's sample rate out of a system_profiler dump.
rate_for_device() {
  printf '%s\n' "$1" | awk -v want="$2" '
    /^[[:space:]]*[A-Za-z0-9][^:]*:[[:space:]]*$/ {
      name = $0
      gsub(/^[[:space:]]+/, "", name)
      sub(/:[[:space:]]*$/, "", name)
      next
    }
    /Current SampleRate:/ {
      rate = $0
      sub(/.*Current SampleRate:[[:space:]]*/, "", rate)
      gsub(/[[:space:]]/, "", rate)
      if (name == want) { print rate; exit }
    }
  '
}

# ------------------------------------------------------------ device lookup ---

list_avf_audio_devices() {
  { ffmpeg -f avfoundation -list_devices true -i "" -hide_banner 2>&1 </dev/null || true; } | awk '
    /AVFoundation video devices:/ { in_audio = 0; next }
    /AVFoundation audio devices:/ { in_audio = 1; next }
    in_audio {
      line = $0
      sub(/^\[[^]]*@[^]]*\][ \t]*/, "", line)
      if (match(line, /^\[[0-9]+\]/)) {
        idx  = substr(line, RSTART + 1, RLENGTH - 2)
        name = substr(line, RSTART + RLENGTH)
        sub(/^[ \t]+/, "", name); sub(/[ \t\r]+$/, "", name)
        print idx "\t" name
      }
    }
  '
}

find_avf_index() {
  local want="$1" devices idx name
  devices="$(list_avf_audio_devices)"
  [[ -n "$devices" ]] || return 1
  while IFS=$'\t' read -r idx name; do
    [[ "$name" == "$want" ]] && { printf '%s' "$idx"; return 0; }
  done <<< "$devices"
  return 1
}

# --------------------------------------------------------------- prescribe ----

prescribe() {
  local json="$1"
  local verdict clicks drops err implied file_rate
  verdict="$(printf '%s' "$json"  | sed -n 's/.*"verdict"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  clicks="$(printf '%s' "$json"   | sed -n 's/.*"clicks"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1)"
  drops="$(printf '%s' "$json"    | sed -n 's/.*"dropouts"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1)"
  err="$(printf '%s' "$json"      | sed -n 's/.*"speed_error_pct"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9.]*\).*/\1/p' | head -n1)"
  implied="$(printf '%s' "$json"  | sed -n 's/.*"implied_true_rate"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1)"
  file_rate="$(printf '%s' "$json"| sed -n 's/.*"file_sample_rate"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1)"
  local loss
  loss="$(printf '%s' "$json" | sed -n 's/.*"content_loss_pct"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9.]*\).*/\1/p' | head -n1)"

  c_hdr "Diagnosis"

  local rate_ok=1
  case "$verdict" in
    *"sample-rate mismatch"*)
      rate_ok=0
      c_red "  Sample-rate mismatch (speed error ${err}%)."
      echo
      echo "  The audio was really running at ${implied} Hz but the capture"
      echo "  recorded it as ${file_rate} Hz. That is exactly why playback is"
      echo "  the wrong speed, and the resyncs are what you hear as pops."
      echo
      echo "  Fix — make every device agree on one rate:"
      echo
      echo "    1. Open Audio MIDI Setup."
      echo "    2. Click '$BLACKHOLE_NAME' -> set Format to ${implied} Hz."
      echo "    3. Click your speakers/headphones -> set Format to ${implied} Hz."
      echo "    4. Click '$MULTI_OUT_NAME' and confirm both members now agree."
      echo
      c_dim "  Every member of a Multi-Output Device must share one rate; macOS"
      c_dim "  will not resample between them cleanly."
      ;;
    *"clock drift"*)
      rate_ok=0
      c_ylw "  Clock drift (speed error ${err}%)."
      echo
      echo "  The rates nominally match but the devices are not locked to a"
      echo "  single clock, so the capture slowly slides out of step."
      echo
      echo "  Fix — in Audio MIDI Setup, select '$MULTI_OUT_NAME':"
      echo
      echo "    1. Your real speakers/headphones must be the PRIMARY (top row)."
      echo "    2. Drift Correction ON for '$BLACKHOLE_NAME'."
      echo "    3. Drift Correction OFF for the primary device."
      echo
      c_dim "  If a Bluetooth device is a member, remove it — Bluetooth clocks"
      c_dim "  drift badly and cannot be corrected reliably."
      ;;
    *"dropped audio"*)
      rate_ok=0
      c_red "  Audio is being DROPPED — ${loss}% of the content never made it."
      echo
      echo "  Pitch is correct (speed error ${err}%) and ffmpeg would report a"
      echo "  healthy 1.00x, because the stream splices back together with no gap."
      echo "  Material is simply missing. That is what 'sounds fast' is here — not"
      echo "  a pitch shift, but chunks of audio going astray."
      echo
      echo "  This is a buffer problem: BlackHole is being fed faster than its"
      echo "  clock consumes, so it overflows and discards what will not fit."
      echo
      echo "  Fix, in this order:"
      echo
      echo "    1. Set '$BLACKHOLE_NAME' Clock Source back to 'Internal Fixed'."
      echo "       On 'Internal Adjustable' an off-centre Balance slider makes the"
      echo "       feed and the clock disagree permanently, which is exactly this."
      echo "    2. In '$MULTI_OUT_NAME': Drift Correction ON for '$BLACKHOLE_NAME',"
      echo "       OFF for the primary device."
      echo "    3. Confirm both members are set to the same rate in Audio MIDI Setup."
      echo "    4. Remove any Bluetooth device from the Multi-Output."
      ;;
    *"clock is correct"*)
      c_grn "  Clock is correct (speed error ${err}%) — no rate mismatch."
      if [[ -n "$loss" ]] && awk -v l="$loss" 'BEGIN { exit !(l > 0.5) }'; then
        echo
        c_ylw "  But ${loss}% of the content is missing — some audio was dropped."
      fi
      ;;
    *)
      c_ylw "  $verdict"
      ;;
  esac

  if [[ "${clicks:-0}" -gt 0 || "${drops:-0}" -gt 0 ]]; then
    echo
    c_ylw "  Glitches found: ${clicks:-0} clicks, ${drops:-0} dropouts."
    if [[ "$rate_ok" -eq 1 ]]; then
      echo
      echo "  The clock is fine, so these are buffer problems, not rate problems:"
      echo
      echo "    * Drift Correction should be ON for '$BLACKHOLE_NAME' and OFF for"
      echo "      the primary device."
      echo "    * Remove any Bluetooth device from the Multi-Output Device."
      echo "    * Close other audio apps holding the device open (DAWs, Zoom,"
      echo "      browsers with live streams)."
      echo "    * If it started recently and audio is degraded system-wide,"
      echo "      reload CoreAudio:"
      echo "        sudo launchctl kickstart -k system/com.apple.audio.coreaudiod"
    else
      c_dim "  Expect these to disappear once the rate/clock issue above is fixed."
    fi
  elif [[ "$rate_ok" -eq 1 ]]; then
    echo
    c_grn "  No clicks or dropouts either — this capture path is clean."
    c_dim "  If you still hear problems, they are in the source material or the"
    c_dim "  playback app rather than the capture chain."
  fi
}

# -------------------------------------------------------------------- main ----

[[ "$(uname -s)" == "Darwin" ]] || die "this script only works on macOS"
command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg not found — brew install ffmpeg"
command -v python3 >/dev/null 2>&1 || die "python3 not found"
write_analyzer

if [[ "$MODE" == "selftest" ]]; then
  # Runs the tone generator straight into the analyzer with no audio hardware
  # involved. Anything other than 0% loss / 0 clicks here means the measuring
  # chain itself is faulty, and no result from a real run can be trusted.
  c_hdr "Self-test (no audio hardware involved)"
  T="$WORKDIR/selftest.wav"
  ffmpeg -v error -f lavfi \
    -i "sine=frequency=${TONE_HZ}:duration=${TONE_SECONDS}:sample_rate=48000" \
    -ac 2 -c:a pcm_s16le "$T"
  python3 "$ANALYZER" "$T" "$TONE_HZ" "$TONE_SECONDS"
  if python3 "$ANALYZER" "$T" "$TONE_HZ" "$TONE_SECONDS" --json \
     | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if abs(d['content_loss_pct'])<0.5 and d['clicks']==0 and abs(d['speed_error_pct'])<0.1 else 1)"; then
    echo; c_grn "  Measuring chain is clean — any loss in a real run comes from the audio path."
  else
    echo; c_red "  Measuring chain is NOT clean. Do not trust real-run numbers."
  fi
  exit 0
fi

if [[ "$MODE" == "analyze" ]]; then
  [[ -f "$ANALYZE_FILE" ]] || die "no such file: $ANALYZE_FILE"
  c_hdr "Analysing $ANALYZE_FILE (expecting a ${TONE_HZ} Hz tone)"
  python3 "$ANALYZER" "$ANALYZE_FILE" "$TONE_HZ" $EXPECT_SECONDS
  prescribe "$(python3 "$ANALYZER" "$ANALYZE_FILE" "$TONE_HZ" $EXPECT_SECONDS --json)"
  exit 0
fi

report_rates
[[ "$MODE" == "rates" ]] && exit 0

command -v SwitchAudioSource >/dev/null 2>&1 || die "SwitchAudioSource not found — brew install switchaudio-osx"
command -v afplay >/dev/null 2>&1 || die "afplay not found (it ships with macOS)"

BH_INDEX="$(find_avf_index "$BLACKHOLE_NAME")" \
  || die "'$BLACKHOLE_NAME' is not available as an ffmpeg audio input"

# --no-monitor sends output straight to BlackHole, bypassing the Multi-Output
# entirely. If drops vanish in that mode, the aggregation is at fault; if they
# persist, BlackHole itself (or its clock setting) is.
if [[ "$MONITOR" -eq 1 ]]; then
  TEST_OUTPUT="$MULTI_OUT_NAME"
else
  TEST_OUTPUT="$BLACKHOLE_NAME"
  c_ylw "--no-monitor: bypassing the Multi-Output. You will NOT hear the tone."
fi

SwitchAudioSource -a -t output | grep -Fxq "$TEST_OUTPUT" \
  || die "output device '$TEST_OUTPUT' not found"

c_hdr "Loopback test"
c_dim "playing a ${TONE_HZ} Hz tone for ${TONE_SECONDS}s through '$TEST_OUTPUT'"
c_dim "and capturing it from '$BLACKHOLE_NAME' [$BH_INDEX]"
[[ "$MONITOR" -eq 1 ]] && c_ylw "you will hear a steady tone — that is expected. Keep the volume up."

TONE="$WORKDIR/tone.wav"
CAPTURE="$WORKDIR/capture.wav"

# Generate the tone at whatever rate the capture device is ALREADY running at.
# An earlier version hardcoded 48000, which made CoreAudio switch BlackHole to
# 48000 on playback and left the speakers stranded at their old rate — the test
# was creating the mismatch it then reported. Never perturb what you measure.
load_sp_dump
TONE_RATE="$(rate_for_device "$SP_DUMP" "$BLACKHOLE_NAME")"
case "$TONE_RATE" in
  8000|11025|16000|22050|24000|32000|44100|48000|88200|96000) ;;
  *) TONE_RATE=48000 ;;
esac
c_dim "generating the tone at ${TONE_RATE} Hz to match '$BLACKHOLE_NAME'"
ffmpeg -v error -f lavfi \
  -i "sine=frequency=${TONE_HZ}:duration=${TONE_SECONDS}:sample_rate=${TONE_RATE}" \
  -ac 2 -c:a pcm_s16le "$TONE"

ORIGINAL_OUTPUT="$(SwitchAudioSource -c -t output 2>/dev/null || true)"
SwitchAudioSource -s "$TEST_OUTPUT" -t output >/dev/null
SWITCHED=1
sleep 1

# NOTE: deliberately NO -ar here. Resampling on the way out would silently
# correct a rate mismatch and hide the very bug we are looking for. Capture
# whatever avfoundation reports, at whatever rate it claims.
CAPTURE_START="$(now_seconds)"
ffmpeg -v error -f avfoundation -i ":$BH_INDEX" -c:a pcm_s16le "$CAPTURE" &
FF_PID=$!

# Wait for the capture to actually produce data instead of sleeping a fixed
# amount. Opening an avfoundation device can take well over a second; a fixed
# sleep meant the head of the tone was never captured, and the analyzer scored
# that startup cost as "content loss" — a constant ~0.65s on every run.
wait_for_capture() {
  local last=0 cur grew=0 tries=0
  while [[ "$tries" -lt 150 ]]; do   # up to ~15s
    tries=$((tries + 1))
    if [[ -f "$CAPTURE" ]]; then cur=$(wc -c < "$CAPTURE" 2>/dev/null || echo 0); else cur=0; fi
    if [[ "$cur" -gt 1024 && "$cur" -gt "$last" ]]; then
      grew=$((grew + 1))
      [[ "$grew" -ge 2 ]] && return 0
    fi
    [[ "$cur" -gt 200000 ]] && return 0
    last=$cur
    sleep 0.1
  done
  return 1
}

if wait_for_capture; then
  c_dim "capture is live; starting playback"
else
  c_ylw "capture never started producing data — results below are unreliable"
fi
sleep 0.3

afplay "$TONE" || true
sleep 1.5

kill -INT "$FF_PID" 2>/dev/null || true
wait "$FF_PID" 2>/dev/null || true
CAPTURE_END="$(now_seconds)"

if [[ "$SWITCHED" -eq 1 && -n "$ORIGINAL_OUTPUT" ]]; then
  SwitchAudioSource -s "$ORIGINAL_OUTPUT" -t output >/dev/null 2>&1 || true
  SWITCHED=0
fi

[[ -s "$CAPTURE" ]] || die "captured nothing — check microphone permission for your terminal"

# THE discriminator. ffmpeg captures continuously, so if the file holds as many
# seconds of audio as the capture ran for, the capture dropped nothing and any
# missing tone is on the playback side or in this harness. If the file is short,
# samples genuinely went missing on the way in. Without this, "content missing"
# cannot tell those two apart — and they have completely different causes.
c_hdr "Capture timing (informational)"
WALL="$(awk -v a="$CAPTURE_START" -v b="$CAPTURE_END" 'BEGIN { printf "%.3f", b - a }')"
FILE_SECS="$(python3 -c "
import wave,sys
try:
    w=wave.open(sys.argv[1],'rb'); print('%.3f' % (w.getnframes()/w.getframerate())); w.close()
except Exception: print('0')
" "$CAPTURE")"
echo "  ffmpeg ran for   : ${WALL} s (includes device open + finalize)"
echo "  audio in file    : ${FILE_SECS} s"
c_dim "  The difference is process startup and shutdown, not lost audio — neither"
c_dim "  interval is capturing. An earlier version reported that gap as sample loss;"
c_dim "  it was wrong. Content loss is measured from cycle count below instead."

c_hdr "Measurements"
python3 "$ANALYZER" "$CAPTURE" "$TONE_HZ" "$TONE_SECONDS"
prescribe "$(python3 "$ANALYZER" "$CAPTURE" "$TONE_HZ" "$TONE_SECONDS" --json)"
