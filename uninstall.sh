#!/usr/bin/env bash
# Uninstaller for context-cycle. Removes the skill + hook files and the
# SessionStart hook entry from settings.json. Leaves saved checkpoints in place.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SKILL_DIR="$CLAUDE_DIR/skills/context-cycle"
HOOK="$CLAUDE_DIR/hooks/context-cycle-restore.mjs"
SETTINGS="$CLAUDE_DIR/settings.json"

echo "Removing context-cycle from: $CLAUDE_DIR"
rm -rf "$SKILL_DIR"
rm -f  "$HOOK"
rm -f  "$CLAUDE_DIR/context-cycle/armed.json" "$CLAUDE_DIR/context-cycle/.pending-file"
echo "  removed skill + hook files"

if [ -f "$SETTINGS" ]; then
  SETTINGS="$SETTINGS" node - <<'NODE'
const fs = require('fs');
const p = process.env.SETTINGS;
let s;
try { s = JSON.parse(fs.readFileSync(p, 'utf8')); }
catch (e) { console.error('  settings.json not valid JSON — left untouched.'); process.exit(0); }
if (!s.hooks || !Array.isArray(s.hooks.SessionStart)) { console.log('  settings: no SessionStart hooks — nothing to remove'); process.exit(0); }
const before = s.hooks.SessionStart.length;
s.hooks.SessionStart = s.hooks.SessionStart.filter(
  (e) => !JSON.stringify(e).includes('context-cycle-restore')
);
if (s.hooks.SessionStart.length === before) { console.log('  settings: hook entry not found — nothing to remove'); process.exit(0); }
fs.copyFileSync(p, p + '.bak');
fs.writeFileSync(p, JSON.stringify(s, null, 2) + '\n');
console.log('  settings: SessionStart hook removed (backup: settings.json.bak)');
NODE
fi

echo
echo "Done. Saved checkpoints under $CLAUDE_DIR/context-cycle/checkpoints/ were kept."
echo "Delete them manually if you want them gone. Restart Claude Code to finish."
