---
name: context-cycle
description: Save the current working context, then clear the conversation and auto-restore that context into the fresh session — to reclaim the context window without losing your place. Saves a checkpoint, arms a one-shot SessionStart hook, and prompts you to press /clear; after the clear, the saved context is auto-injected into the new session. Only THIS skill arms the restore — a normal /clear does nothing. Triggers: context cycle, recycle context, save clear and restore, free up context, compact my context, reset context but keep my place.
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
  - Grep
---

# /context-cycle — Save → (you press /clear) → auto-restore

Reclaims the context window mid-task: capture the working state to a checkpoint,
arm a one-shot restore, and hand you off to a single `/clear`. After you clear, a
`SessionStart` hook injects the saved context straight into the fresh session, so
you resume without losing your place.

**Why one manual keystroke:** Claude Code does not let a skill or hook run `/clear`
(it discards history, so it is gated behind a human). This skill automates the save
and the restore; you press `/clear` once in the middle.

**HARD GATE:** Do NOT implement or modify code. This skill only reads state, writes
one checkpoint file, and arms the restore flag.

---

## Step 1 — Compute the checkpoint path and gather git state

Run this Bash block verbatim. Set `TITLE_RAW` to the user's title if they gave one
after the command (e.g. `/context-cycle auth refactor` → `TITLE_RAW="auth refactor"`),
otherwise leave it as `context-cycle`. The title is sanitized in bash (allowlist),
so it is safe against shell metacharacters.

```bash
TITLE_RAW="context-cycle"   # <-- replace with the user's title if provided

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Project slug from the git repo (fallback: current dir name).
SLUG=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" | tr -cd 'a-zA-Z0-9._-')
SLUG="${SLUG:-no-git}"

# Optional gstack integration: if gstack is installed, save into its checkpoint
# dir so /context-restore and /context-save list see this checkpoint too.
# Otherwise use a standalone location under the Claude config dir.
CHECKPOINT_DIR=""
if [ -x "$CLAUDE_DIR/skills/gstack/bin/gstack-slug" ]; then
  eval "$("$CLAUDE_DIR/skills/gstack/bin/gstack-slug" 2>/dev/null)" 2>/dev/null || true
  eval "$("$CLAUDE_DIR/skills/gstack/bin/gstack-paths" 2>/dev/null)" 2>/dev/null || true
  [ -n "${SLUG:-}" ] || SLUG="no-git"
  [ -n "${GSTACK_STATE_ROOT:-}" ] && CHECKPOINT_DIR="$GSTACK_STATE_ROOT/projects/$SLUG/checkpoints"
fi
[ -n "$CHECKPOINT_DIR" ] || CHECKPOINT_DIR="$CLAUDE_DIR/context-cycle/checkpoints/$SLUG"
mkdir -p "$CHECKPOINT_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TITLE_SLUG=$(printf '%s' "${TITLE_RAW:-context-cycle}" | tr '[:upper:]' '[:lower:]' | tr -s ' \t' '-' | tr -cd 'a-z0-9.-' | cut -c1-60)
TITLE_SLUG="${TITLE_SLUG:-context-cycle}"
FILE="$CHECKPOINT_DIR/${TIMESTAMP}-${TITLE_SLUG}.md"
[ -e "$FILE" ] && FILE="$CHECKPOINT_DIR/${TIMESTAMP}-${TITLE_SLUG}-$(printf '%04x' "$$").md"

# Stash the path for arm.sh (Step 3) so no path has to round-trip through the model.
mkdir -p "$CLAUDE_DIR/context-cycle"
printf '%s\n' "$FILE" > "$CLAUDE_DIR/context-cycle/.pending-file"

echo "FILE=$FILE"
echo "BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
echo "ISO=$(date +%Y-%m-%dT%H:%M:%S%z)"
echo "=== STATUS ==="; git status --short 2>/dev/null
echo "=== DIFF STAT ==="; git diff --stat 2>/dev/null
echo "=== STAGED DIFF STAT ==="; git diff --cached --stat 2>/dev/null
echo "=== RECENT LOG ==="; git log --oneline -10 2>/dev/null
```

## Step 2 — Write the checkpoint file

Using the git state above **plus the conversation so far**, write the checkpoint to
the **exact** `FILE` path printed in Step 1 (use the Write tool). Use this format:

```markdown
---
status: in-progress
branch: {BRANCH from Step 1}
timestamp: {ISO from Step 1}
files_modified:
  - path/one
  - path/two
---

## Working on: {concise title, 3-6 words}

### Summary
{1-3 sentences: the high-level goal and where things stand right now}

### Decisions Made
{bulleted architectural choices / trade-offs / approaches chosen and why}

### Remaining Work
{numbered next steps, in priority order — this is what the restored session resumes from}

### Notes
{gotchas, blocked items, open questions, dead ends already tried}
```

`files_modified` comes from `git status --short` (staged + unstaged), repo-relative
paths. Fill every section from real conversation context — this file IS what the
fresh session will see, so make it self-sufficient for someone with zero memory.

## Step 3 — Arm the one-shot restore

```bash
bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/context-cycle/arm.sh"
```

This reads the path from Step 1's `.pending-file`, writes `armed.json`, and prints
`ARMED -> <path>`. If it prints an error instead, STOP and report it — do not tell
the user to clear.

## Step 4 — Hand off to /clear

Print exactly this (fill in the values), then STOP. Do not clear anything yourself
(you can't) and do not continue working.

```
CONTEXT CYCLED — READY TO CLEAR
════════════════════════════════════════
Saved:   {title}
Branch:  {branch}
File:    {FILE}
Armed:   one-shot restore (this project, expires in 1h)
════════════════════════════════════════

Now press  /clear  — your saved context auto-restores into the fresh session.
(A normal /clear you didn't set up this way restores nothing.)
```

---

## Important rules

- **Never modify code.** Save state, write one file, arm the flag. Nothing else.
- **You cannot run `/clear` for the user** — no skill or hook can. Always hand off.
- **One-shot, fresh, same-project.** The hook fires once, only on a `/clear`, only
  within an hour of arming, and only in the project you armed it in, then disarms.
  A `/clear` in a different project leaves the flag armed for the right one; any
  other `/clear` is a silent no-op.
- **Checkpoints are append-only.** Each cycle writes a new file; nothing is
  overwritten or deleted.
- If `arm.sh` fails, the restore is NOT armed — say so and don't prompt for `/clear`.
