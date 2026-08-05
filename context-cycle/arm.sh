#!/usr/bin/env bash
# Arm the /context-cycle one-shot restore flag.
#
# Usage:  bash arm.sh /abs/path/to/checkpoint.md
#
# The checkpoint path is REQUIRED and must be the literal absolute path printed as
# FILE= by the skill's Step 1. It is deliberately NOT read back from a shared
# "pending path" file: that file was machine-global (not scoped by session or by
# project), and Step 2 — writing several KB of checkpoint prose — sits between the
# write and the read. A second session's Step 1 landing in that window silently
# retargeted the first session's arm at the second session's checkpoint.
#
# Writes one arm flag per (project, session):
#   <claude-dir>/context-cycle/armed.d/<projecthash>-<sessionkey>.json
# so two concurrent sessions cannot clobber each other. The SessionStart hook
# consumes the oldest fresh arm matching the project the /clear happened in.
#
# Re-arming from the SAME session overwrites that session's own flag (newest
# checkpoint wins, no accumulation). Arming from a DIFFERENT session adds a
# separate flag.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STATE_DIR="$CLAUDE_DIR/context-cycle"
ARM_DIR="$STATE_DIR/armed.d"
mkdir -p "$ARM_DIR"

die() { printf 'arm.sh: %s\n' "$1" >&2; exit 1; }

CP="${1:-}"
# Trim surrounding whitespace so an all-whitespace argument counts as empty.
CP="$(printf '%s' "$CP" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

if [ -z "$CP" ]; then
  die "missing checkpoint path.
  Usage: bash arm.sh /abs/path/to/checkpoint.md
  Pass the LITERAL absolute path printed as FILE= by Step 1. Shell variables set
  in an earlier Bash call do not survive into this one — there is no fallback."
fi

case "$CP" in
  *'$'*)
    die "argument looks like an unexpanded shell variable: $CP
  Each Claude Code Bash call is a fresh shell, so \$FILE from Step 1 is empty here.
  Substitute the literal absolute path printed as FILE= by Step 1." ;;
esac

case "$CP" in
  /*|[A-Za-z]:/*|[A-Za-z]:\\*) : ;;
  *) die "checkpoint path must be absolute, got: $CP" ;;
esac

[ -f "$CP" ] || die "checkpoint file not found: $CP
  Write the checkpoint (Step 2) before arming (Step 3)."
[ -s "$CP" ] || die "checkpoint file is empty: $CP
  Write the checkpoint contents (Step 2) before arming (Step 3)."

# Native Windows node reads C:/... not MSYS /c/...; convert when possible so the
# hook (which runs under native node on Windows) can read the checkpoint path.
if command -v cygpath >/dev/null 2>&1; then
  CP_NODE=$(cygpath -m "$CP")
else
  CP_NODE=$(printf '%s' "$CP" | sed -E 's#^/([a-zA-Z])/#\U\1:/#')
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
# Project scope: the repo root this cycle belongs to. The restore hook only fires
# when the cleared session is in this same project. Fall back to $PWD outside git.
CWD=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
NOW=$(date +%s)

# Short stable hash, used only to build a filename. The JSON "cwd" field below is
# what actually gates the restore, so a hash collision cannot mis-fire a restore —
# at worst two projects would share one arm slot. cksum is the POSIX last resort.
hash12() {
  if command -v sha1sum >/dev/null 2>&1; then printf '%s' "$1" | sha1sum | cut -c1-12
  elif command -v shasum  >/dev/null 2>&1; then printf '%s' "$1" | shasum  | cut -c1-12
  elif command -v md5sum  >/dev/null 2>&1; then printf '%s' "$1" | md5sum  | cut -c1-12
  else printf '%s' "$1" | cksum | tr -cd '0-9' | cut -c1-12
  fi
}

# Session key. CLAUDE_CODE_SESSION_ID is set in the skill's bash environment; it is
# useless at restore time (a /clear mints a new session id and the SessionStart
# payload carries no link to the pre-clear one) but it is exactly what is needed
# here: it keeps a session from clobbering ANOTHER session's arm while still
# letting it supersede its own. Unset -> "nosession", which degrades to the old
# one-arm-per-project behaviour.
SESS=$(printf '%s' "${CLAUDE_CODE_SESSION_ID:-}" | tr -cd 'a-zA-Z0-9-' | cut -c1-40)
[ -n "$SESS" ] || SESS="nosession"

DEST="$ARM_DIR/$(hash12 "$CWD")-$SESS.json"

# JSON-escape backslashes and quotes.
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
ESC_CP=$(esc "$CP_NODE")
ESC_BR=$(esc "$BRANCH")
ESC_CWD=$(esc "$CWD")

# Write via temp + rename so the hook never reads a half-written flag.
TMP="$ARM_DIR/.tmp.$$.json"
cat > "$TMP" <<EOF
{
  "checkpoint": "$ESC_CP",
  "branch": "$ESC_BR",
  "cwd": "$ESC_CWD",
  "armed_at": $NOW
}
EOF
mv -f "$TMP" "$DEST" 2>/dev/null || { cp -f "$TMP" "$DEST"; rm -f "$TMP"; }

# Reap arms and temp files past the hook's TTL (3600s). Never touches checkpoints.
find "$ARM_DIR" -maxdepth 1 -type f -name '*.json' -mmin +60 -delete 2>/dev/null || true

echo "ARMED -> $CP_NODE"
echo "ARM_FLAG -> $DEST"
