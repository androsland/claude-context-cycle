#!/usr/bin/env bash
# Installer for context-cycle — a Claude Code skill + SessionStart hook.
#
#   Clone:  git clone https://github.com/androsland/claude-context-cycle && cd claude-context-cycle && ./install.sh
#   Or:     curl -fsSL https://raw.githubusercontent.com/androsland/claude-context-cycle/main/install.sh | bash
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/androsland/claude-context-cycle/main"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SKILL_DIR="$CLAUDE_DIR/skills/context-cycle"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"

# Where this script lives (empty when piped through `curl | bash`).
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

say()  { printf '  %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v node >/dev/null 2>&1 || die "node is required (the restore hook runs on Node.js). Install Node 18+ and retry."
command -v bash >/dev/null 2>&1 || die "bash is required."

BACKED_UP=()

# Copy a repo file to a destination — from the local clone if present, else
# download. An installed file that differs from the shipped one is backed up
# first: reinstalling used to revert a locally patched copy with no diff, no
# prompt and no way back, which is exactly how this tool's own fixes were
# developed and tested. Matches the settings.json backup below — ONE .bak per
# file, overwritten each run, so backups cannot pile up generation by generation.
# Unchanged files are left alone entirely, so a no-op reinstall writes no .bak.
fetch() { # $1 = repo-relative path, $2 = destination
  local rel="$1" dest="$2" src tmp=""

  # Both copies below operate on a symlinked destination's TARGET, not the link:
  # `cp "$dest" "$dest.bak"` reads the target's contents out to a predictable
  # path, and `cp "$src" "$dest"` writes straight through into it. Refuse rather
  # than silently unlink — symlinking an installed file at a local checkout is a
  # real dev setup, and replacing the link with a copy would break it with no
  # way to notice.
  if [ -L "$dest" ]; then
    die "$dest is a symlink, not a regular file.
  Refusing to install through it: backing it up would copy the link TARGET's
  contents to $dest.bak, and installing would write through the link into that
  target. If you linked this to a local checkout on purpose, remove the link (or
  point CLAUDE_CONFIG_DIR somewhere else) and re-run."
  fi

  if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/$rel" ]; then
    src="$SELF_DIR/$rel"
  else
    tmp="$(mktemp "${TMPDIR:-/tmp}/context-cycle.XXXXXX")" || die "could not create a temp file"
    curl -fsSL "$REPO_RAW/$rel" -o "$tmp" || { rm -f "$tmp"; die "failed to download $rel"; }
    src="$tmp"
  fi

  if [ -f "$dest" ] && ! cmp -s "$src" "$dest"; then
    if ! cp "$dest" "$dest.bak"; then
      if [ -n "$tmp" ]; then rm -f "$tmp"; fi
      die "could not back up $dest — refusing to overwrite it."
    fi
    BACKED_UP+=("$dest.bak")
  fi

  # Clean up on both paths explicitly. Under `set -e` a failing `cp` aborts the
  # function outright, so a trailing `rm -f "$tmp"` would simply never run and
  # the downloaded file would be left behind.
  if ! cp "$src" "$dest"; then
    if [ -n "$tmp" ]; then rm -f "$tmp"; fi
    die "could not write $dest"
  fi
  if [ -n "$tmp" ]; then rm -f "$tmp"; fi
  return 0
}

echo "Installing context-cycle into: $CLAUDE_DIR"
mkdir -p "$SKILL_DIR" "$HOOKS_DIR" "$CLAUDE_DIR/context-cycle"

fetch "context-cycle/SKILL.md"                "$SKILL_DIR/SKILL.md"
fetch "context-cycle/arm.sh"                  "$SKILL_DIR/arm.sh"
fetch "hooks/context-cycle-restore.mjs"       "$HOOKS_DIR/context-cycle-restore.mjs"
chmod +x "$SKILL_DIR/arm.sh" "$HOOKS_DIR/context-cycle-restore.mjs" 2>/dev/null || true
say "skill  -> $SKILL_DIR/"
say "hook   -> $HOOKS_DIR/context-cycle-restore.mjs"

if [ "${#BACKED_UP[@]}" -gt 0 ]; then
  say "note: these files differed from the shipped version and were overwritten."
  say "      your copy is preserved alongside each one:"
  for b in "${BACKED_UP[@]}"; do say "      $b"; done
fi

# Merge the SessionStart hook into settings.json (idempotent; backs up first).
CLAUDE_DIR="$CLAUDE_DIR" SETTINGS="$SETTINGS" node - <<'NODE'
const fs = require('fs'), os = require('os'), path = require('path');
const settingsPath = process.env.SETTINGS;
const claudeDir = process.env.CLAUDE_DIR;

let s = {};
if (fs.existsSync(settingsPath)) {
  try { s = JSON.parse(fs.readFileSync(settingsPath, 'utf8')); }
  catch (e) { console.error('  settings.json is not valid JSON — leaving it untouched.'); process.exit(1); }
}

s.hooks = s.hooks || {};
s.hooks.SessionStart = s.hooks.SessionStart || [];

const already = JSON.stringify(s.hooks.SessionStart).includes('context-cycle-restore');
if (already) { console.log('  settings: SessionStart hook already present — skipped'); process.exit(0); }

// Use the portable $HOME/.claude form for the default dir; otherwise embed the path.
const isDefault = path.resolve(claudeDir) === path.resolve(path.join(os.homedir(), '.claude'));
const hookPath = isDefault
  ? '$HOME/.claude/hooks/context-cycle-restore.mjs'
  : (claudeDir.replace(/\\/g, '/') + '/hooks/context-cycle-restore.mjs');
const command = `bash -c 'node ${hookPath}'`;

if (fs.existsSync(settingsPath)) fs.copyFileSync(settingsPath, settingsPath + '.bak');
s.hooks.SessionStart.push({ hooks: [{ type: 'command', command }] });
fs.writeFileSync(settingsPath, JSON.stringify(s, null, 2) + '\n');
console.log('  settings: SessionStart hook added' + (fs.existsSync(settingsPath + '.bak') ? ' (backup: settings.json.bak)' : ''));
NODE

echo
echo "Done. One more step: restart Claude Code so it loads the new hook."
echo "Then run  /context-cycle  in any project to try it."
