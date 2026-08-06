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

die() { printf 'arm.sh: %s\n' "$1" >&2; exit 1; }

# Resolve the config root to its physical path BEFORE building any path under it.
# `~/.claude` is very often a symlink into a dotfiles repo (stow, chezmoi, a bare
# git checkout) — that is a legitimate setup and must keep working, so the root
# itself is deliberately allowed to be a link.
mkdir -p "$CLAUDE_DIR" 2>/dev/null || true
CLAUDE_DIR_P=$(cd "$CLAUDE_DIR" 2>/dev/null && pwd -P) || CLAUDE_DIR_P=""
[ -n "$CLAUDE_DIR_P" ] || CLAUDE_DIR_P="$CLAUDE_DIR"

STATE_DIR="$CLAUDE_DIR_P/context-cycle"
ARM_DIR="$STATE_DIR/armed.d"

# What must NOT be a symlink is anything the tool creates below that root. armed.d
# is enumerated and unlink-swept by the restore hook, so a link swapped in at
# EITHER level makes the sweep delete *.json out of the link's target instead —
# checking only the leaf misses it, because the OS resolves a symlinked parent
# during traversal and the leaf check then sees a perfectly real directory.
for d in "$STATE_DIR" "$ARM_DIR"; do
  [ -L "$d" ] && die "$d is a symlink, not a directory.
  Refusing to write arm flags through it: the restore hook enumerates and deletes
  *.json in that directory, which through a link means deleting someone else's
  files. Remove the link and re-run.
  (Note: \$CLAUDE_CONFIG_DIR / ~/.claude itself MAY be a symlink — that is a
  normal dotfiles setup. Only context-cycle/ and armed.d/ must be real.)"
done
mkdir -p "$ARM_DIR"

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

# A raw control byte inside a JSON string is invalid JSON, and esc() below is
# line-oriented, so an embedded newline would split the value across lines. The
# resulting flag parses as garbage and is silently ignored until the hook's litter
# sweep reaps it, which is seven days away.
# Refuse loudly instead — a checkpoint path has no legitimate control characters.
case "$CP" in
  *[[:cntrl:]]*) die "checkpoint path contains a control character. Rename the file." ;;
esac

[ -f "$CP" ] || die "checkpoint file not found: $CP
  Write the checkpoint (Step 2) before arming (Step 3)."
[ -s "$CP" ] || die "checkpoint file is empty: $CP
  Write the checkpoint contents (Step 2) before arming (Step 3)."

# Native Windows node reads C:/... not MSYS /c/..., so convert — but ONLY when
# actually running under MSYS/Cygwin. On Linux and macOS `/c/foo` is an ordinary
# absolute path, and rewriting it to `C:/foo` points the hook at a file that does
# not exist. The previous unconditional `sed -E 's#^/([a-zA-Z])/#\U\1:/#'` did
# exactly that to any checkpoint under a single-letter top-level directory, and
# `\U` is a GNU extension that BSD sed does not implement at all.
CP_NODE="$CP"
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*)
    if command -v cygpath >/dev/null 2>&1; then
      CP_NODE=$(cygpath -m "$CP")
    else
      # Same conversion without GNU sed: /c/x -> C:/x, anything else untouched.
      # shellcheck disable=SC2018,SC2019  # The case pattern already constrains this to a
      # single ASCII letter — a drive letter. The suggested [:lower:]/[:upper:] classes
      # buy nothing here and are locale-dependent in tr, so the ranges are the safer form.
      case "$CP" in
        /[A-Za-z]/*) CP_NODE="$(printf '%s' "$CP" | cut -c2 | tr 'a-z' 'A-Z'):${CP#/?}" ;;
      esac
    fi ;;
esac

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
# Project scope: the repo root this cycle belongs to. The restore hook only fires
# when the cleared session is in this same project. Fall back to $PWD outside git.
CWD=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
NOW=$(date +%s)

# Same reason as the checkpoint-path check: a control byte here produces an
# unparseable flag, which fails *silently* (no restore, no error). Fail loudly.
case "$CWD" in
  *[[:cntrl:]]*) die "project path contains a control character: cannot arm safely." ;;
esac

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

# JSON-escape backslashes and quotes. Control bytes are stripped as a backstop:
# $CP and $CWD are already rejected above, and git forbids them in ref names, so
# nothing should reach here with one — but emitting invalid JSON fails silently,
# and dropping a byte from a cosmetic branch label does not.
esc() { printf '%s' "$1" | tr -d '\000-\037\177' | sed 's/\\/\\\\/g; s/"/\\"/g'; }
ESC_CP=$(esc "$CP_NODE")
ESC_BR=$(esc "$BRANCH")
ESC_CWD=$(esc "$CWD")

# Re-check right before writing. The guard above ran before mkdir and before several
# subprocesses (git, date, sha1sum) — long enough for someone with write access to
# $STATE_DIR to swap in a link afterwards. This narrows that window; it does not close
# it, and bash has no atomic way to. It is cheap, so it is worth having.
for d in "$STATE_DIR" "$ARM_DIR"; do
  [ -L "$d" ] && die "$d became a symlink while arming. Refusing to write through it."
done

# Write via temp + rename so the hook never reads a half-written flag.
#
# mktemp, not ".tmp.$$": a PID is sequential and guessable, and `cat >` follows an
# existing symlink — so a pre-placed .tmp.<PID> link pointed anywhere would have this
# script write the flag straight into that file. mktemp creates with O_EXCL, which
# fails on a symlink instead of following it, and picks an unpredictable name.
# The `.tmp.` prefix is load-bearing: the hook skips those when reading arms and
# reaps them separately past the litter horizon.
TMP=$(mktemp "$ARM_DIR/.tmp.XXXXXX") || die "could not create a temp file in $ARM_DIR"
cat > "$TMP" <<EOF
{
  "checkpoint": "$ESC_CP",
  "branch": "$ESC_BR",
  "cwd": "$ESC_CWD",
  "armed_at": $NOW
}
EOF
# `mv` renames the directory entry and never dereferences an existing $DEST, so the
# normal path is safe. `cp` DOES follow a destination symlink, and $DEST is fully
# predictable (hash of the project path + session id) — so unlink first and let cp
# create a fresh file.
mv -f "$TMP" "$DEST" 2>/dev/null || { rm -f "$DEST"; cp -f "$TMP" "$DEST"; rm -f "$TMP"; }

# Reap abandoned temp files past the litter horizon (7 days = 10080 min, matching the
# hook's LITTER_TTL_SECONDS). Never touches checkpoints.
#
# It deliberately no longer touches *.json. Arms do not expire any more, and this
# script cannot parse JSON to tell a live arm from a corrupt one — while armed.d/ is
# shared across ALL projects. The previous `-name '*.json' ... -mmin +60` therefore
# meant that arming a cycle in one project silently deleted another project's arm that
# was still sitting there waiting for its own /clear. Collecting corrupt flags is left
# to the hook, which can actually parse them and can tell the difference.
#
# `find` does not follow a symlinked start point (POSIX default, -P), so a link
# swapped in for $ARM_DIR makes this a no-op rather than a delete elsewhere —
# verified against GNU findutils 4.8.0.
find "$ARM_DIR" -maxdepth 1 -type f -name '.tmp.*' -mmin +10080 -delete 2>/dev/null || true

echo "ARMED -> $CP_NODE"
echo "ARM_FLAG -> $DEST"
