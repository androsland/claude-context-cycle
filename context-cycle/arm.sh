#!/usr/bin/env bash
# Arm the /context-cycle one-shot restore flag.
#
# Usage:  bash arm.sh [/abs/path/to/checkpoint.md]
# If no path is given, reads it from <claude-dir>/context-cycle/.pending-file
# (written by the skill's Step 1). Writes <claude-dir>/context-cycle/armed.json,
# which the SessionStart hook consumes on the next /clear in this project.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STATE_DIR="$CLAUDE_DIR/context-cycle"
PEND="$STATE_DIR/.pending-file"
mkdir -p "$STATE_DIR"

CP="${1:-}"
if [ -z "$CP" ] && [ -f "$PEND" ]; then
  CP=$(head -n1 "$PEND" 2>/dev/null || true)
fi
if [ -z "$CP" ]; then
  echo "arm.sh: no checkpoint path (arg or .pending-file)" >&2
  exit 1
fi
if [ ! -f "$CP" ]; then
  echo "arm.sh: checkpoint file not found: $CP" >&2
  exit 1
fi

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

# JSON-escape backslashes and quotes.
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
ESC_CP=$(esc "$CP_NODE")
ESC_BR=$(esc "$BRANCH")
ESC_CWD=$(esc "$CWD")

cat > "$STATE_DIR/armed.json" <<EOF
{
  "checkpoint": "$ESC_CP",
  "branch": "$ESC_BR",
  "cwd": "$ESC_CWD",
  "armed_at": $NOW
}
EOF

rm -f "$PEND" 2>/dev/null || true
echo "ARMED -> $CP_NODE"
