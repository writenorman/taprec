#!/usr/bin/env bash
#
# install.sh — install taprec for one user or for everyone on the machine.
#
#   ./install.sh                   # just you        -> ~/.local/bin
#   sudo ./install.sh --system     # all users       -> /usr/local/bin
#   ./install.sh --prefix /opt/foo # somewhere else
#   ./install.sh --uninstall       # remove (add --system / --prefix to match)
#   ./install.sh --with-tools      # also install tools/verify-recording.sh
#
# A system install also copies the AudioTee binary to <prefix>/libexec/taprec/
# so every user shares it. Without that, each user would have to run
# `taprec --install` separately in their own home.
#
set -euo pipefail

PREFIX=""
SYSTEM=0
UNINSTALL=0
WITH_TOOLS=0

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

c_red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
c_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
c_dim() { printf '\033[2m%s\033[0m\n' "$*"; }
die()   { c_red "error: $*"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --system)     SYSTEM=1;        shift ;;
    --prefix)     PREFIX="${2:-}"; shift 2 ;;
    --uninstall)  UNINSTALL=1;     shift ;;
    --with-tools) WITH_TOOLS=1;    shift ;;
    -h|--help)    sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            die "unknown option: $1" ;;
  esac
done

# Under `sudo`, $HOME may be root's. The AudioTee we want to share, and the
# ~/.local we'd install into, belong to the human who typed sudo — not to root.
REAL_HOME="$HOME"
if [[ -n "${SUDO_USER:-}" ]]; then
  sudo_home="$(eval echo "~$SUDO_USER" 2>/dev/null || true)"
  [[ -d "$sudo_home" ]] && REAL_HOME="$sudo_home"
fi

if [[ -z "$PREFIX" ]]; then
  if [[ "$SYSTEM" -eq 1 ]]; then
    PREFIX="/usr/local"
  else
    PREFIX="$REAL_HOME/.local"
    if [[ -n "${SUDO_USER:-}" ]]; then
      c_ylw "note: running under sudo without --system."
      c_dim "  Installing to $PREFIX (${SUDO_USER}'s home), not machine-wide."
      c_dim "  For all users:  sudo ./install.sh --system"
      echo
    fi
  fi
fi

BIN_DIR="$PREFIX/bin"
LIBEXEC_DIR="$PREFIX/libexec/taprec"

# A "shared" install is anything outside the invoking user's own ~/.local.
SHARED=0
[[ "$SYSTEM" -eq 1 || "$PREFIX" != "$REAL_HOME/.local" ]] && SHARED=1

# ------------------------------------------------------------------ uninstall -

if [[ "$UNINSTALL" -eq 1 ]]; then
  removed=0
  for f in "$BIN_DIR/taprec" "$BIN_DIR/taprec-verify" "$LIBEXEC_DIR/audiotee"; do
    # -L as well: a dangling symlink from an older `ln -s` install fails -e.
    if [[ -e "$f" || -L "$f" ]]; then
      rm -f "$f"
      c_dim "removed $f"
      removed=$((removed + 1))
    fi
  done
  if [[ -d "$LIBEXEC_DIR" ]]; then
    rmdir "$LIBEXEC_DIR" 2>/dev/null || true
  fi
  if [[ "$removed" -eq 0 ]]; then
    c_ylw "nothing found under $PREFIX — was it installed somewhere else?"
    c_dim "  try:  command -v taprec"
  else
    c_grn "✔ removed $removed file(s)"
    c_dim "  AudioTee in $REAL_HOME/.local/share and your recordings are untouched."
  fi
  exit 0
fi

# -------------------------------------------------------------------- install -

[[ -f "$SRC_DIR/taprec" ]] || die "taprec not found next to this script"

if [[ ! -d "$BIN_DIR" ]]; then
  mkdir -p "$BIN_DIR" 2>/dev/null \
    || die "cannot create $BIN_DIR — for a system install, re-run with sudo"
fi
[[ -w "$BIN_DIR" ]] || die "$BIN_DIR is not writable — for a system install, re-run with sudo"

install -m 0755 "$SRC_DIR/taprec" "$BIN_DIR/taprec"
c_grn "✔ installed $BIN_DIR/taprec"

if [[ "$WITH_TOOLS" -eq 1 ]]; then
  if [[ -f "$SRC_DIR/tools/verify-recording.sh" ]]; then
    install -m 0755 "$SRC_DIR/tools/verify-recording.sh" "$BIN_DIR/taprec-verify"
    c_grn "✔ installed $BIN_DIR/taprec-verify"
  else
    c_ylw "⚠ --with-tools: tools/verify-recording.sh not found, skipped"
  fi
fi

# Share the AudioTee binary so other users don't each need `taprec --install`.
# taprec looks for <dir of taprec>/../libexec/taprec/audiotee, which is exactly
# where this puts it.
if [[ "$SHARED" -eq 1 ]]; then
  AT_SRC=""
  for cand in \
    "${AUDIOTEE_HOME:-$REAL_HOME/.local/share/audiotee}/bin/audiotee" \
    "${AUDIOTEE_HOME:-$REAL_HOME/.local/share/audiotee}/src/.build/release/audiotee" \
    "$HOME/.local/share/audiotee/bin/audiotee"
  do
    [[ -x "$cand" ]] && { AT_SRC="$cand"; break; }
  done

  if [[ -n "$AT_SRC" ]]; then
    mkdir -p "$LIBEXEC_DIR" 2>/dev/null || die "cannot create $LIBEXEC_DIR"
    install -m 0755 "$AT_SRC" "$LIBEXEC_DIR/audiotee"
    if [[ "$SYSTEM" -eq 1 ]]; then
      c_grn "✔ installed $LIBEXEC_DIR/audiotee  (shared by all users)"
    else
      c_grn "✔ installed $LIBEXEC_DIR/audiotee"
    fi
    if "$LIBEXEC_DIR/audiotee" --help 2>&1 | grep -q -- '--stereo'; then
      c_dim "  stereo-capable build"
    else
      c_ylw "  mono-only build — stereo needs a source build (see README)"
      c_dim "    taprec --install --from-source   then re-run this installer"
    fi
  else
    c_ylw "⚠ no AudioTee binary found to share."
    c_dim "  Run 'taprec --install' first, then re-run this installer —"
    c_dim "  otherwise every user has to run 'taprec --install' themselves."
  fi
fi

# ------------------------------------------------------------------- warnings -

echo
if ! printf '%s' ":$PATH:" | grep -q ":$BIN_DIR:"; then
  c_ylw "⚠ $BIN_DIR is not on your PATH."
  if [[ "$BIN_DIR" == "/usr/local/bin" ]]; then
    c_dim "  Unusual — /usr/local/bin is normally listed in /etc/paths."
    c_dim "  Check:  cat /etc/paths"
  else
    c_dim "  Add to ~/.zshrc:  export PATH=\"$BIN_DIR:\$PATH\""
  fi
  echo
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  c_ylw "⚠ ffmpeg not found on PATH — taprec needs it."
  c_dim "  brew install ffmpeg"
  echo
elif [[ "$SHARED" -eq 1 ]]; then
  FF="$(command -v ffmpeg)"
  case "$FF" in
    /opt/homebrew/*|/usr/local/Cellar/*|*/homebrew/*|*/linuxbrew/*)
      c_ylw "⚠ ffmpeg is at $FF"
      c_dim "  Homebrew's bin directory is put on PATH by your shell profile, so"
      c_dim "  OTHER users on this Mac may not find ffmpeg even though you can."
      c_dim "  To make it system-wide:"
      c_dim "    echo '$(dirname "$FF")' | sudo tee /etc/paths.d/homebrew"
      echo
      ;;
  esac
fi

if [[ "$SHARED" -eq 1 ]]; then
  cat <<'EOF'
One thing an installer cannot do for you:

  macOS grants audio-capture permission PER USER, to the terminal application —
  not to taprec, and not machine-wide. Every user who wants to record must
  approve it once for their own terminal:

    System Settings → Privacy & Security → Screen & System Audio Recording
      → "System Audio Recording Only"  (a separate list, below the main one)
      → enable Terminal / iTerm / whichever they use

  Until then their recordings come out silent, with no error. `taprec --check`
  reports whether the current user is set up.

EOF
fi

c_dim "verify with:  taprec --version && taprec --check"
