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

Run this with `<CHECKPOINT-PATH>` replaced by the **literal absolute path** printed
as `FILE=` in Step 1 — the same path you just wrote to in Step 2:

```bash
bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/context-cycle/arm.sh" "<CHECKPOINT-PATH>"
```

Worked example — if Step 1 printed
`FILE=/home/you/.claude/context-cycle/checkpoints/myrepo/20260805-141233-auth-refactor.md`:

```bash
bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/context-cycle/arm.sh" "/home/you/.claude/context-cycle/checkpoints/myrepo/20260805-141233-auth-refactor.md"
```

**Never write `"$FILE"` (or any other variable) as the argument.** Every Claude Code
Bash call is a fresh shell, so `$FILE` from Step 1 no longer exists here and would
expand to an empty string. `arm.sh` refuses an empty, whitespace-only, `$`-containing,
or relative argument rather than guessing — there is no fallback path to silently pick
up the wrong session's checkpoint.

On success it prints `ARMED -> <path>` and `ARM_FLAG -> <flag file>`. If it prints an
error instead, STOP and report it — do not tell the user to clear.

## Step 4 — Hand off to /clear

Print exactly this (fill in the values), then STOP. Do not clear anything yourself
(you can't) and do not continue working.

```
CONTEXT CYCLED — READY TO CLEAR
════════════════════════════════════════
Saved:   {title}
Branch:  {branch}
File:    {FILE}
Armed:   one-shot restore (this project, waits until you clear)
════════════════════════════════════════

Now press  /clear  — your saved context auto-restores into the fresh session.
(A normal /clear you didn't set up this way restores nothing.)
```

---

## Important rules

- **Never modify code.** Save state, write one file, arm the flag. Nothing else.
- **You cannot run `/clear` for the user** — no skill or hook can. Always hand off.
- **One-shot, same-project, no deadline.** The hook fires once, only on a `/clear`,
  and only in the project you armed it in, then disarms that one arm. A `/clear` in a
  different project leaves the flag armed for the right one; any other `/clear` is a
  silent no-op. The arm does **not** expire — clearing days later still restores, and
  a restore that old discloses its age and any branch change rather than passing
  itself off as current. (`CONTEXT_CYCLE_TTL=<seconds>` reinstates a bound for anyone
  who wants one; unset means none.)
- **Concurrency-safe by construction.** The checkpoint path goes straight from
  Step 1 to `arm.sh` as an argument, and each arm is its own file keyed by
  (project, session) under `context-cycle/armed.d/`. Nothing about one session's
  cycle is reachable — or overwritable — by another session's.
- **Checkpoints are append-only.** Each cycle writes a new file; nothing is
  overwritten or deleted. The hook deletes arm flags only, never a checkpoint.
- **The restore only reads from checkpoint directories.** The hook accepts a
  `checkpoint` path under `$CLAUDE_DIR/context-cycle/checkpoints`, under
  `$GSTACK_STATE_ROOT/projects` — the two locations Step 1 above writes to — or under
  anything in `CONTEXT_CYCLE_CHECKPOINT_ROOTS` (`PATH`-style, `:` on Unix, `;` on
  Windows). Both sides are resolved first, so a symlinked config dir matches and a
  symlink escaping a root does not. Anything else is refused with a visible line and
  the arm is **kept**, not consumed — so a legitimate location that this misses costs
  one env var and a second `/clear`, never a lost checkpoint. If you change where
  Step 1 writes, change this too. The hook derives `GSTACK_STATE_ROOT` from the
  environment rather than running `gstack-paths`, because it will not execute another
  tool on the restore path.
- If `arm.sh` fails, the restore is NOT armed — say so and don't prompt for `/clear`.

---

## Non-goals and known limits

Scope statements, not caveats: an unstated limit reads as a claim of coverage.

**Must keep working — do not "simplify" these away:**

- The plain single-session cycle: `/context-cycle` → `/clear` right after → restore
  fires. This is the overwhelmingly common path and everything else is subordinate
  to it.
- **Re-arming within one session.** Running `/context-cycle` twice before clearing
  supersedes that session's own earlier arm, so the newest checkpoint is the one
  restored and no stale flag is left behind.
- A `/clear` with nothing armed stays a silent no-op, and a `/clear` in project X
  never consumes an arm belonging to project Y.
- Non-git directories, gstack's checkpoint directory, a session whose Bash calls
  `cd`'d elsewhere in the repo, and a session started in a subdirectory of the repo
  all still arm and restore.
- The Windows/MSYS path conversions in `arm.sh` (`cygpath -m`, the `/c/` → `C:/`
  fallback) and in the hook (`norm()`, the `win32` branch) are load-bearing on
  native Windows and are not exercised by WSL testing. Leave them intact.

**Known blind spots — the design structurally cannot see these:**

- **Two sessions in the same project that clear out of arming order.** `/clear`
  mints a brand-new session id, and the SessionStart payload carries no link back
  to the pre-clear session (verified against Claude Code 2.1.222: the payload is
  `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `source`, and
  `session_id` differs on either side of the clear). The hook therefore cannot tell
  *which* session is clearing. It hands out the oldest pending arm for the project:
  correct when sessions clear in the order they armed, mis-paired when they don't.
  Nothing is lost either way — every checkpoint file is still on disk and each
  session's arm is a separate file — and the clear-time banner names the checkpoint
  that was restored, so a mis-pair is visible rather than silent.
- **An abandoned arm, now with no deadline.** If a session arms and never clears, the
  next `/clear` in that same project consumes that arm — there is no signal
  distinguishing "the session that armed this" from "some other session in the same
  project". Removing the 1h TTL widened this from a one-hour window to an open-ended
  one: an arm forgotten last month is still waiting. That was a deliberate trade —
  the bound broke the ordinary "clear it tomorrow" case far more often than it caught
  a forgotten arm — and it is mitigated, not closed, by the age and branch-drift lines
  on any restore older than 4 hours. The mitigation is disclosure only: the restore
  still happens, and the user still has to notice.
- **The branch-drift half of that disclosure goes quiet in a worktree or submodule.**
  The branch is read from `.git/HEAD`, and in a linked worktree or submodule `.git` is
  a *file* pointing at a gitdir elsewhere. Rather than walk up — which would report the
  superproject's branch and so invent drift, or hide it — the hook reports no branch at
  all, and says nothing about drift either way. The age line is unaffected. (Until
  recently that same worktree lost the restore *entirely* when it sat inside its main
  repo and its path crossed a symlink or a Windows short name — the scope guard refused
  the arm before the branch was ever read. Fixed; the missing drift line is all that is
  left of it.)
- **A subdirectory *inside* a nested repo.** The scope gate looks for `.git` in the
  clearing session's own cwd, so a `/clear` at a nested repo's root is correctly
  rejected at any depth (`repo/a/b/nested` does not match an arm taken at `repo`).
  But it only inspects that one directory, never the path between — so a `/clear` at
  `repo/a/b/nested/src` still matches `repo`'s arm, because `src` itself holds no
  `.git`. Walking up to the nearest repo boundary would close it, at the cost of a
  stat per ancestor on every session start.
- **A symlinked route into your project that *sits* inside a repo-shaped ancestor of
  it.** When the path you cleared in resolves somewhere else, the gate decides whether
  that route is legitimate by asking whether it stayed inside the repository the path
  belongs to as written. Where an ancestor of your project is itself repo-shaped, a
  link living under that ancestor resolves to somewhere still inside it and clears that
  test — so what decides it is where the link sits, not where it points. The precondition is
  weaker than "you use yadm", too: the boundary walk stops at any entry named `.git`,
  file or directory, real repository or not. A link someone else shipped in a repo you
  cloned therefore passes exactly as readily as a shortcut you made yourself, because
  the two are the same mechanism. Bounded by what it yields: the content injected is
  your own checkpoint, and the session's cwd physically *is* the armed project.
- **Anything an attacker can write *inside* a checkpoint root.** Confining
  `checkpoint` to the known roots closes an arbitrary-file-**read**: an arm flag can no
  longer name `~/.ssh/id_rsa` and have it injected as model context. It does not close
  prompt **injection**. `armed.d/` and `checkpoints/` are siblings under
  `context-cycle/`, so whoever can plant an arm flag can almost always plant the file
  it points at too, and that file is inside a root by construction. The check narrows
  what can be injected, not whether — closing that needs a provenance check on the arm
  itself, which is still open in `TODOS.md`. It also cannot see *content*: a file the
  user wrote themselves and a file an attacker wrote sit in the same directory and look
  identical to a path check.
- **A checkpoint root that is neither of the two this repo knows.** The roots are
  derived from the environment, and gstack's is derived by reimplementing its
  `GSTACK_STATE_ROOT` chain rather than asking it — so a future gstack that changes
  that chain, or any third integration that writes checkpoints somewhere else, gets
  refused until someone sets `CONTEXT_CYCLE_CHECKPOINT_ROOTS`. That refusal is the
  designed failure mode (loud, arm preserved, one variable to fix) rather than an
  oversight, but it is a real coupling to another project's private detail and it will
  not announce itself when that detail moves.
- **A Claude Code version that stops sending `source` on SessionStart.** The hook
  requires `source === 'clear'` and fails closed, so the restore would stop firing
  entirely rather than fire on unrelated session starts. That is deliberate: the
  loud failure is recoverable, a blind fire consumes the arm and injects stale
  context into a session that never asked for it.
