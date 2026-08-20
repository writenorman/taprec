#!/usr/bin/env bash
#
# verify-recording.sh — check a REAL recording against the file that produced it.
#
# Every earlier measurement in this saga went through a synthetic tone played by
# afplay, which is not how you actually record. This compares an actual recording
# of actual audio against its source and reports whether they drift apart.
#
# How: build a loudness envelope of both, align the recording to the source in
# successive windows, and watch the alignment offset. Clean capture => the offset
# stays flat. Dropped audio => the offset climbs, and the growth IS the lost
# content. Immune to when recording started/stopped and to padding at either end.
#
# Usage:
#   ./verify-recording.sh -s track.mp3 -r recordings/system-audio-....wav
#
set -euo pipefail

SOURCE=""
RECORDING=""
RATE=8000     # envelope work only; no need for full bandwidth

c_red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
c_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
c_dim() { printf '\033[2m%s\033[0m\n' "$*"; }
c_hdr() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()   { c_red "error: $*"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--source)    SOURCE="${2:-}";    shift 2 ;;
    -r|--recording) RECORDING="${2:-}"; shift 2 ;;
    -h|--help)      sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              die "unknown option: $1" ;;
  esac
done

[[ -n "$SOURCE" ]]    || die "need -s <source audio file>"
[[ -n "$RECORDING" ]] || die "need -r <recording>"
[[ -f "$SOURCE" ]]    || die "no such file: $SOURCE"
[[ -f "$RECORDING" ]] || die "no such file: $RECORDING"
command -v ffmpeg >/dev/null 2>&1  || die "ffmpeg not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify-rec.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

cat > "$WORK/compare.py" <<'PYEOF'
#!/usr/bin/env python3
"""
compare_to_source.py — measure whether a recording drifts away from its source.

Aligns a recording against the file that produced it, in successive windows. A
clean capture holds a constant alignment offset; a capture that drops audio
falls progressively behind, and the growth in offset IS the lost content.

Immune to when recording started/stopped and to padding at either end — only
relative drift matters.

Two things this had to handle that a naive version does not:

  * Loudness alone is not enough. Compressed dance music has a nearly flat
    loudness envelope, so single-band RMS correlation has nothing to lock onto.
    We use three crude spectral bands (low / high / total) instead, which stay
    distinctive even when overall level is constant.

  * Sources can be an hour long while the recording is a minute. Searching every
    lag at full resolution is far too slow, so the global search runs on
    decimated envelopes and only the winner is refined at full resolution.

Pure standard library — stock macOS python3, no numpy.

Usage: compare_to_source.py <source.raw> <recording.raw> <rate> [--json]
       (both inputs mono 16-bit raw PCM at <rate>, produced by ffmpeg)
"""

import array
import json
import sys

HOP_MS = 25.0
DECIM = 8          # coarse-search decimation
CONF_MIN = 0.55    # per-window confidence floor
NBANDS = 3


def load_raw(path):
    data = open(path, "rb").read()
    samples = array.array("h")
    samples.frombytes(data[: len(data) - (len(data) % 2)])
    if sys.byteorder == "big":
        samples.byteswap()
    return samples


def band_envelopes(samples, rate):
    """
    Three coarse energy curves per hop: total, high-frequency, low-frequency.

    High band via first difference (a 1-pole highpass), low band via adjacent
    sum (a 1-pole lowpass). Crude, but enough to tell a bassline from a hi-hat,
    which is exactly the discrimination a flat-loudness mix needs.
    """
    hop = max(1, int(rate * HOP_MS / 1000.0))
    tot, hi, lo = [], [], []
    n = len(samples)
    for start in range(0, n - hop + 1, hop):
        st = si = sl = 0
        prev = samples[start]
        for i in range(start, start + hop):
            v = samples[i]
            st += v * v
            d = v - prev
            si += d * d
            a = (v + prev) >> 1
            sl += a * a
            prev = v
        tot.append((st / hop) ** 0.5)
        hi.append((si / hop) ** 0.5)
        lo.append((sl / hop) ** 0.5)
    return [tot, hi, lo]


def decimate(seq, factor):
    out = []
    for i in range(0, len(seq) - factor + 1, factor):
        out.append(sum(seq[i : i + factor]) / factor)
    return out


def normalize(seq):
    n = len(seq)
    if n == 0:
        return None
    mean = sum(seq) / n
    centered = [v - mean for v in seq]
    norm = sum(v * v for v in centered) ** 0.5
    if norm <= 0:
        return None
    return [v / norm for v in centered]


def prep_window(bands, start, length):
    """Normalized per-band slice, or None if any band is flat/silent."""
    out = []
    for b in bands:
        if start < 0 or start + length > len(b):
            return None
        w = normalize(b[start : start + length])
        if w is None:
            return None
        out.append(w)
    return out


def score_at(src_bands, win, lag):
    """Mean per-band normalized correlation."""
    length = len(win[0])
    total = 0.0
    for b_idx, b in enumerate(src_bands):
        if lag < 0 or lag + length > len(b):
            return -1.0
        seg = normalize(b[lag : lag + length])
        if seg is None:
            return -1.0
        total += sum(a * c for a, c in zip(seg, win[b_idx]))
    return total / len(src_bands)


def best_lag(src_bands, win, lo, hi):
    best, best_score = None, -2.0
    for lag in range(lo, hi + 1):
        sc = score_at(src_bands, win, lag)
        if sc > best_score:
            best_score, best = sc, lag
    return best, best_score


def first_loud(env, frac=0.1):
    peak = max(env) if env else 0
    if peak <= 0:
        return 0
    for i, v in enumerate(env):
        if v > peak * frac:
            return i
    return 0


def last_loud(env, frac=0.1):
    peak = max(env) if env else 0
    if peak <= 0:
        return len(env)
    for i in range(len(env) - 1, -1, -1):
        if env[i] > peak * frac:
            return i + 1
    return len(env)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    as_json = "--json" in sys.argv[1:]
    if len(args) < 3:
        raise SystemExit("usage: compare_to_source.py <source.raw> <recording.raw> <rate> [--json]")

    src_path, rec_path, rate = args[0], args[1], int(args[2])
    fps = 1000.0 / HOP_MS

    src_bands = band_envelopes(load_raw(src_path), rate)
    rec_bands = band_envelopes(load_raw(rec_path), rate)

    if len(src_bands[0]) < 40 or len(rec_bands[0]) < 40:
        raise SystemExit("one of the files is too short to compare")

    win = int(2.5 * fps)
    if len(rec_bands[0]) < win * 2:
        win = max(int(1 * fps), len(rec_bands[0]) // 3)

    rec_start = first_loud(rec_bands[0])
    rec_end = last_loud(rec_bands[0])
    if rec_end - rec_start < win:
        raise SystemExit("not enough audible audio in the recording to compare")

    # --- global lock: coarse on decimated envelopes, then refine -------------
    src_d = [decimate(b, DECIM) for b in src_bands]
    rec_d = [decimate(b, DECIM) for b in rec_bands]
    win_d = max(4, win // DECIM)
    probe_d = prep_window(rec_d, rec_start // DECIM, win_d)
    if probe_d is None:
        raise SystemExit("the recording appears to be silent")

    coarse, coarse_score = best_lag(src_d, probe_d, 0, max(0, len(src_d[0]) - win_d))
    if coarse is None:
        raise SystemExit("could not locate the recording within the source")

    probe = prep_window(rec_bands, rec_start, win)
    if probe is None:
        raise SystemExit("the recording appears to be silent")
    centre = coarse * DECIM
    start_lag, start_score = best_lag(
        src_bands, probe,
        max(0, centre - 3 * DECIM),
        min(len(src_bands[0]) - win, centre + 3 * DECIM),
    )
    if start_lag is None:
        raise SystemExit("could not refine the alignment")

    # --- walk the recording -------------------------------------------------
    points = []
    step = win
    pos = rec_start
    lag_guess = start_lag - win     # so the first iteration lands on start_lag
    while pos + win <= rec_end:
        w = prep_window(rec_bands, pos, win)
        if w is None:
            pos += step
            continue
        # Window length and search band are coupled. A 6s window with 6.7% loss
        # drifts 0.4s WITHIN itself, so no single lag aligns it and everything
        # fails. Short windows fix that but then a wide forward band lets each
        # window jump to a spurious match and drift accumulates falsely. 2.5s
        # windows with a +0.6s band is the pairing that measured correctly on
        # both flat-loudness dance material and dynamic material.
        expected = lag_guess + step
        lo = max(0, expected - int(0.15 * fps))
        hi = min(len(src_bands[0]) - win, expected + int(0.6 * fps))
        if hi < lo:
            break
        lag, sc = best_lag(src_bands, w, lo, hi)
        if lag is None:
            break
        points.append({
            "at_sec": round(pos / fps, 2),
            "offset_sec": round((lag - pos) / fps, 3),
            "confidence": round(sc, 3),
        })
        lag_guess = lag
        pos += step

    if len(points) < 2:
        raise SystemExit("could not align the recording to the source")

    good = [p for p in points if p["confidence"] > CONF_MIN]
    if len(good) < 2:
        res = {
            "aligned": False,
            "reason": "alignment confidence too low",
            "global_lock_score": round(start_score, 3),
            "best_window_confidence": round(max(p["confidence"] for p in points), 3),
            "points": points,
        }
        if as_json:
            print(json.dumps(res, indent=2))
        else:
            print(f"  {res['reason']}")
            print(f"  global lock score      : {res['global_lock_score']}")
            print(f"  best window confidence : {res['best_window_confidence']}")
            print()
            print("  Likely causes: the source file is not what was playing, the")
            print("  recording is silent, or the material is too uniform to align.")
        return

    drift = good[-1]["offset_sec"] - good[0]["offset_sec"]
    span = good[-1]["at_sec"] - good[0]["at_sec"]
    loss = (drift / span * 100.0) if span > 0 else 0.0

    res = {
        "aligned": True,
        "windows": len(good),
        "span_sec": round(span, 2),
        "drift_sec": round(drift, 3),
        "content_loss_pct": round(loss, 2),
        "global_lock_score": round(start_score, 3),
        "mean_confidence": round(sum(p["confidence"] for p in good) / len(good), 3),
        "points": good,
    }

    if as_json:
        print(json.dumps(res, indent=2))
        return

    print(f"  windows aligned  : {res['windows']}")
    print(f"  span measured    : {res['span_sec']} s")
    print(f"  alignment drift  : {res['drift_sec']:+.3f} s")
    print(f"  content loss     : {res['content_loss_pct']:+.2f}%")
    print(f"  global lock      : {res['global_lock_score']}")
    print(f"  mean confidence  : {res['mean_confidence']}")
    print()
    print("  offset per window (flat = clean, climbing = losing audio):")
    for p in good:
        print(f"    t={p['at_sec']:7.2f}s  offset={p['offset_sec']:+8.3f}s  conf={p['confidence']:.3f}")


if __name__ == "__main__":
    main()
PYEOF

c_hdr "Decoding"
c_dim "  source    : $SOURCE"
c_dim "  recording : $RECORDING"
ffmpeg -v error -i "$SOURCE"    -f s16le -ar "$RATE" -ac 1 "$WORK/src.raw" || die "could not decode the source"
ffmpeg -v error -i "$RECORDING" -f s16le -ar "$RATE" -ac 1 "$WORK/rec.raw" || die "could not decode the recording"

c_hdr "Alignment"
python3 "$WORK/compare.py" "$WORK/src.raw" "$WORK/rec.raw" "$RATE" || die "comparison failed"

JSON="$(python3 "$WORK/compare.py" "$WORK/src.raw" "$WORK/rec.raw" "$RATE" --json 2>/dev/null || true)"
LOSS="$(printf '%s' "$JSON" | sed -n 's/.*"content_loss_pct"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9.]*\).*/\1/p' | head -n1)"
CONF="$(printf '%s' "$JSON" | sed -n 's/.*"mean_confidence"[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p' | head -n1)"

c_hdr "Verdict"
if [[ -z "$LOSS" ]]; then
  c_ylw "  Could not align."
  c_dim "  If the global lock score above is high but window confidence is low,"
  c_dim "  the source is right and the recording is badly damaged. If BOTH are"
  c_dim "  low, the source file probably is not what was playing."
  exit 1
fi

MAG="$(awk -v l="$LOSS" 'BEGIN { printf "%.2f", (l < 0 ? -l : l) }')"
if awk -v m="$MAG" 'BEGIN { exit !(m < 1.0) }'; then
  c_grn "  Clean — ${LOSS}% drift over the recording."
  c_dim "  The capture kept up with the source. Whatever the tone test was"
  c_dim "  measuring, it is not affecting real recordings."
elif awk -v m="$MAG" 'BEGIN { exit !(m < 3.0) }'; then
  c_ylw "  Marginal — ${LOSS}% drift. Small but real; probably not audible."
else
  c_red "  Audio IS being lost — ${LOSS}% drift over the recording."
  c_dim "  This confirms the problem is real and not a test artifact."
fi
c_dim "  (mean alignment confidence ${CONF:-?}; below ~0.7 means treat the number"
c_dim "   as approximate — repetitive material aligns loosely.)"
