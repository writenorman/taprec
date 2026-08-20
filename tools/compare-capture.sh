#!/usr/bin/env bash
#
# compare-capture.sh — A/B different capture configurations against the same tone.
#
# Established so far: a BlackHole->BlackHole loopback (ONE device, ONE clock)
# still loses ~512-sample buffers at a fixed ~10/sec, in every device
# configuration. That cannot be a clock or sample-rate fault. It is the capture
# software dropping buffers.
#
# This runs the identical tone through several capture setups and reports which
# one keeps the most audio. Whichever wins is the one to record with.
#
# Usage:
#   ./compare-capture.sh              # through the Multi-Output (real-world path)
#   ./compare-capture.sh --no-monitor # straight to BlackHole (fewest variables)
#
set -euo pipefail

BLACKHOLE_NAME="BlackHole 2ch"
MULTI_OUT_NAME="Multi-Output Device"
TONE_HZ=1000
TONE_SECONDS=10
MONITOR=1
SWEEP=0

c_red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
c_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
c_dim() { printf '\033[2m%s\033[0m\n' "$*"; }
c_hdr() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()   { c_red "error: $*"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-monitor)   MONITOR=0; shift ;;
    --sweep)        SWEEP=1; shift ;;
    -b|--blackhole) BLACKHOLE_NAME="${2:-}"; shift 2 ;;
    -m|--multi-out) MULTI_OUT_NAME="${2:-}"; shift 2 ;;
    -s|--seconds)   TONE_SECONDS="${2:-}"; shift 2 ;;
    -h|--help)      sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              die "unknown option: $1" ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only"
command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg not found"
command -v SwitchAudioSource >/dev/null 2>&1 || die "SwitchAudioSource not found"

WORKDIR="$(mktemp -d /tmp/capture-compare.XXXXXX)"
ANALYZER="$WORKDIR/analyze_capture.py"
ORIGINAL_OUTPUT=""
SWITCHED=0

cleanup() {
  if [[ "$SWITCHED" -eq 1 && -n "$ORIGINAL_OUTPUT" ]]; then
    SWITCHED=0
    SwitchAudioSource -s "$ORIGINAL_OUTPUT" -t output >/dev/null 2>&1 || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

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

BH_INDEX=""
while IFS=$'\t' read -r idx name; do
  [[ "$name" == "$BLACKHOLE_NAME" ]] && BH_INDEX="$idx"
done <<< "$(list_avf_audio_devices)"
[[ -n "$BH_INDEX" ]] || die "'$BLACKHOLE_NAME' not found as an ffmpeg audio input"

if [[ "$MONITOR" -eq 1 ]]; then
  TEST_OUTPUT="$MULTI_OUT_NAME"
else
  TEST_OUTPUT="$BLACKHOLE_NAME"
fi
SwitchAudioSource -a -t output | grep -Fxq "$TEST_OUTPUT" || die "'$TEST_OUTPUT' not found"

TONE="$WORKDIR/tone.wav"
ffmpeg -v error -f lavfi \
  -i "sine=frequency=${TONE_HZ}:duration=${TONE_SECONDS}:sample_rate=48000" \
  -ac 2 -c:a pcm_s16le "$TONE"

ORIGINAL_OUTPUT="$(SwitchAudioSource -c -t output 2>/dev/null || true)"
SwitchAudioSource -s "$TEST_OUTPUT" -t output >/dev/null
SWITCHED=1

wait_for_capture() {
  local f="$1" last=0 cur grew=0 tries=0
  while [[ "$tries" -lt 150 ]]; do
    tries=$((tries + 1))
    if [[ -f "$f" ]]; then cur=$(wc -c < "$f" 2>/dev/null || echo 0); else cur=0; fi
    # Two growths OR a decent absolute size. Requiring three consecutive
    # growths at 100ms was fragile: an encoder that buffers into a few large
    # writes never satisfies it and the run is falsely reported as failed.
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

RESULTS=""

run_variant() {
  local label="$1"; shift
  local out="$WORKDIR/${label}.wav"
  c_dim "  running: $label"

  "$@" "$out" >/dev/null 2>&1 &
  local pid=$!
  if ! wait_for_capture "$out"; then
    kill -INT "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    RESULTS+="${label}\tFAILED\t-\n"
    return 0
  fi
  sleep 0.3
  afplay "$TONE" || true
  sleep 1.2
  kill -INT "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  if [[ ! -s "$out" ]]; then
    RESULTS+="${label}\tNO AUDIO\t-\n"
    return 0
  fi

  local line
  line="$(python3 "$ANALYZER" "$out" "$TONE_HZ" "$TONE_SECONDS" --json 2>/dev/null \
    | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print('%.2f\t%d' % (d['content_loss_pct'], d['clicks']))
except Exception:
    print('ERR\t-')
")"
  RESULTS+="${label}\t${line}\n"
}

if [[ "$SWEEP" -eq 1 ]]; then
  # Does loss scale with duration? A fixed-rate buffer bug holds loss% constant
  # no matter how long you record. An accumulating overflow — producer outpacing
  # consumer until the buffer saturates — makes loss% climb with duration. These
  # have completely different fixes, and the percentage alone cannot tell them
  # apart from a single run.
  c_hdr "Duration sweep (same capture config, increasing tone length)"
  c_dim "played through '$TEST_OUTPUT'"
  echo
  SWEEP_RESULTS=""
  for secs in 5 10 20 40; do
    c_dim "  ${secs}s tone..."
    T="$WORKDIR/sweep_${secs}.wav"
    ffmpeg -v error -f lavfi \
      -i "sine=frequency=${TONE_HZ}:duration=${secs}:sample_rate=48000" \
      -ac 2 -c:a pcm_s16le "$T"
    C="$WORKDIR/sweepcap_${secs}.wav"
    ffmpeg -v error -f avfoundation -i ":$BH_INDEX" -c:a pcm_s16le -y "$C" >/dev/null 2>&1 &
    p=$!
    if wait_for_capture "$C"; then
      sleep 0.3
      afplay "$T" || true
      sleep 1.2
    fi
    kill -INT "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
    if [[ -s "$C" ]]; then
      line="$(python3 "$ANALYZER" "$C" "$TONE_HZ" "$secs" --json 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print('%.2f\t%d\t%.2f' % (d['content_loss_pct'], d['clicks'], d['clicks']/float('$secs')))
except Exception: print('ERR\t-\t-')")"
      SWEEP_RESULTS+="${secs}\t${line}\n"
    else
      SWEEP_RESULTS+="${secs}\tNO AUDIO\t-\t-\n"
    fi
  done

  SwitchAudioSource -s "$ORIGINAL_OUTPUT" -t output >/dev/null 2>&1 || true
  SWITCHED=0

  c_hdr "Results"
  printf "  %8s %12s %8s %10s\n" "duration" "content lost" "clicks" "clicks/sec"
  printf "  %8s %12s %8s %10s\n" "--------" "------------" "------" "----------"
  printf "%b" "$SWEEP_RESULTS" | while IFS=$'\t' read -r d loss clicks rate; do
    [[ -z "$d" ]] && continue
    printf "  %7ss %11s%% %8s %10s\n" "$d" "$loss" "$clicks" "$rate"
  done
  echo
  c_dim "If loss% and clicks/sec stay FLAT: fixed-rate drops in the capture software."
  c_dim "If they CLIMB with duration: an accumulating buffer overflow — the producer"
  c_dim "is outpacing the consumer and the fix is upstream, not in ffmpeg flags."
  exit 0
fi

c_hdr "Comparing capture configurations"
c_dim "tone: ${TONE_HZ} Hz for ${TONE_SECONDS}s, played through '$TEST_OUTPUT'"
echo

# 1. exactly what the recorder does today
run_variant "ffmpeg-baseline" \
  ffmpeg -v error -f avfoundation -i ":$BH_INDEX" -c:a pcm_s16le -y

# 2. the standard fix for ffmpeg dropping live input: a bigger input queue
run_variant "ffmpeg-queue8192" \
  ffmpeg -v error -thread_queue_size 8192 -f avfoundation -i ":$BH_INDEX" -c:a pcm_s16le -y

# 3. bigger queue plus low-latency input flags
run_variant "ffmpeg-queue+nobuf" \
  ffmpeg -v error -thread_queue_size 16384 -fflags +nobuffer -f avfoundation -i ":$BH_INDEX" \
    -c:a pcm_s16le -y

# 4. a completely different capture engine, if it is installed
if command -v sox >/dev/null 2>&1 && sox --help 2>&1 | grep -qi coreaudio; then
  run_variant "sox-coreaudio" \
    sox -q -t coreaudio "$BLACKHOLE_NAME" -b 16 -e signed-integer
else
  RESULTS+="sox-coreaudio\tNOT INSTALLED\t-\n"
fi

SwitchAudioSource -s "$ORIGINAL_OUTPUT" -t output >/dev/null 2>&1 || true
SWITCHED=0

c_hdr "Results"
printf "  %-20s %12s %8s\n" "configuration" "content lost" "clicks"
printf "  %-20s %12s %8s\n" "--------------------" "------------" "--------"
printf "%b" "$RESULTS" | while IFS=$'\t' read -r label loss clicks; do
  [[ -z "$label" ]] && continue
  printf "  %-20s %11s%s %8s\n" "$label" "$loss" \
    "$([[ "$loss" =~ ^[0-9.]+$ ]] && echo '%' || echo ' ')" "$clicks"
done

echo
c_dim "Lowest 'content lost' wins. If one config is near 0% while baseline is"
c_dim "double digits, that is your fix — record with those flags."
c_dim "If ALL of them lose ~10%, the drops are upstream of the capture tool"
c_dim "(BlackHole itself or afplay), and Core Audio taps are the way out."
