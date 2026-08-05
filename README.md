# context-cycle

**Save your working context, `/clear`, and auto-restore it — in one move.** A
[Claude Code](https://docs.anthropic.com/en/docs/claude-code) skill + hook that
reclaims a bloated context window mid-task without losing your place.

You run `/context-cycle`, press `/clear` once, and the fresh session opens with
your saved task state already loaded. That's it.

---

## The problem

Long sessions fill the context window. The usual fix — `/clear` — wipes
everything: what you were building, the decisions you made, what's left to do.
So you either keep paying for a bloated context or clear and lose your place.

`context-cycle` closes that gap. It snapshots the working state to a checkpoint,
clears, and injects the snapshot back into the new session automatically.

## What it does

```
/context-cycle
      │  saves a checkpoint (goal, decisions, remaining work, notes)
      │  arms a one-shot restore for THIS project
      ▼
  you press /clear        ← the one manual step (Claude Code gates this on a human)
      │
      ▼
  fresh session          ← SessionStart hook injects the checkpoint automatically
   ✓ Restored: "auth refactor" · next: wire up token rotation   ← clear-time banner
   …then the session opens with a short recap and resumes where you left off
```

One manual keystroke (`/clear`); everything else is automatic.

## Why one keystroke stays manual

Claude Code does **not** let a skill or a hook run `/clear` (or `/compact`) — those
discard conversation history, so they're deliberately gated behind a human. No tool
call or hook output can trigger them. `context-cycle` automates the two ends (save
and restore) and hands you the middle. A hook is the only thing that survives a
clear, which is exactly what does the restoring.

## Requirements

- **Claude Code**
- **Node.js 18+** (the restore hook runs on Node)
- **bash** (Git Bash on Windows — works out of the box)

Cross-platform: macOS, Linux, and Windows.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/androsland/claude-context-cycle/main/install.sh | bash
```

or from a clone:

```bash
git clone https://github.com/androsland/claude-context-cycle
cd claude-context-cycle
./install.sh
```

The installer copies the skill to `~/.claude/skills/context-cycle/`, the hook to
`~/.claude/hooks/`, and adds one `SessionStart` entry to `~/.claude/settings.json`
(idempotent, and it backs the file up first). **Restart Claude Code once** so it
loads the new hook.

## Usage

```
/context-cycle                 # infers a title from the conversation
/context-cycle auth refactor   # give it your own title
```

Then press **`/clear`** when prompted. The next session restores automatically.

You can also restore manually later — checkpoints are plain markdown on disk (see
below), and if you use [gstack](https://github.com/glweems/gstack) they're written
where `/context-restore` and `/context-save list` can find them too.

## How it works

- **The armed flag is the gate.** `/context-cycle` writes an arm flag under
  `~/.claude/context-cycle/armed.d/` recording the checkpoint path, branch, the
  project's repo root, and a timestamp. The hook does nothing unless a flag
  exists — so a **plain `/clear` never restores anything**.
- **One flag per (project, session).** The filename is
  `<project-hash>-<session-id>.json`, so two sessions cycling at the same time
  can't overwrite each other's pending restore. Re-running `/context-cycle` in
  the *same* session replaces that session's own flag (newest checkpoint wins);
  a *different* session adds its own.
- **SessionStart hook.** After a `/clear`, Claude Code fires a `SessionStart` hook
  with `source: "clear"`. The hook checks the flag and, if valid, injects the saved
  checkpoint, then deletes the flag. It uses **two output channels**, because `/clear`
  does not invoke the model:
  - `hookSpecificOutput.additionalContext` — the full checkpoint, injected into the
    **model's** context (invisible to you). This *is* the restore. It also asks the
    session to open its first reply with a short recap.
  - a top-level **`systemMessage`** — rendered **to you at clear-time**, enriched from
    the checkpoint (`✓ Restored: "<title>" · next: <first remaining-work item>`), so
    you see what came back the instant you clear, not on your next message.

  The output is written with synchronous `writeSync(1, …)`: `process.stdout.write`
  followed by `process.exit()` can truncate a multi-KB checkpoint on the pipe and
  silently drop the whole restore.
- **One-shot.** Consumes exactly one flag, then leaves the rest armed.
- **Project-scoped.** Each flag records the repo root it was armed in. A `/clear` in
  a *different* project is ignored and **leaves the flag armed** for the right one.
  A clear from a *subdirectory* of the armed repo still counts — but not from the
  root of a nested repo or submodule, which is a different project.
- **Self-expiring.** A flag older than 1 hour is treated as stale and cleared, so a
  much-later `/clear` won't surprise-restore. Expired flags are also swept on every
  session start, so `armed.d/` can't grow without bound.
- **Fails closed.** `/clear` mints a brand-new session id and the hook payload carries
  no link back to the pre-clear session, so `source: "clear"` is the only evidence a
  clear actually happened. A missing or unparseable payload restores **nothing** —
  firing blind would burn an arm and inject a checkpoint nobody asked for.

### Known limitation

When **two sessions in the same project** are both armed, the hook consumes the
**oldest** matching flag. That pairs correctly when the sessions clear in the order
they armed, and mis-pairs when they don't — nothing in the `SessionStart` payload
identifies which session is clearing, so the hook cannot do better. This is why the
clear-time banner names the checkpoint it restored (`✓ Restored: "…"`): a mis-pair is
visible immediately rather than silent. Re-run `/context-cycle` if the banner isn't
the checkpoint you expected. Sessions in *different* projects are never affected.

### Where checkpoints live

```
~/.claude/context-cycle/checkpoints/<project-slug>/<timestamp>-<title>.md
```

They're append-only markdown with frontmatter (status, branch, timestamp, modified
files) and sections: Summary, Decisions Made, Remaining Work, Notes. Human-readable
and safe to delete anytime. (With gstack installed, they go to gstack's checkpoint
directory instead, for compatibility with its `/context-restore`.)

## What it touches

| Path | Purpose |
|---|---|
| `~/.claude/skills/context-cycle/` | the skill (`SKILL.md`, `arm.sh`) |
| `~/.claude/hooks/context-cycle-restore.mjs` | the SessionStart restore hook |
| `~/.claude/settings.json` | one added `SessionStart` hook entry |
| `~/.claude/context-cycle/` | arm flags (`armed.d/`) + saved checkpoints |

It never modifies your code, and it doesn't phone home.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/androsland/claude-context-cycle/main/uninstall.sh | bash
# or, from a clone:  ./uninstall.sh
```

Removes the files and the settings entry (backing up `settings.json`). Saved
checkpoints are kept — delete them yourself if you want them gone.

## Tests

```bash
bash test/run-tests.sh
```

58 assertions across 14 groups — concurrent arms, project scoping, TTL sweeping,
`arm.sh` argument validation, fail-closed payload handling, legacy-flag migration,
full multi-KB payload delivery, and a hostile state dir (symlinked `armed.d`,
control characters in paths). It runs the repo's own `arm.sh` and hook against
a throwaway `CLAUDE_CONFIG_DIR` in a temp dir, so it never reads or writes your real
`~/.claude` and never touches an installed copy. Needs bash, node, and git — nothing
else.

## FAQ

**Can't it just clear for me?** No. `/clear` is user-only by design in Claude Code.
This automates the save and the restore around it.

**Does a normal `/clear` trigger a restore?** No. Only a `/clear` you set up with
`/context-cycle` (which arms the flag) restores. Everything else is a no-op.

**Do I need gstack?** No — it's fully standalone. If you happen to have gstack, it
integrates automatically with `/context-restore`.

**Custom config dir?** The installer honors `CLAUDE_CONFIG_DIR` if set.

## License

MIT © Andreas Demetriou. See [LICENSE](LICENSE).
