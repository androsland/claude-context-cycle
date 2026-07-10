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
   "✓ Restored context via /context-cycle"   ← visible confirmation, then you
                                                pick up exactly where you left off
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

- **The armed flag is the gate.** `/context-cycle` writes
  `~/.claude/context-cycle/armed.json` recording the checkpoint path, branch, the
  project's repo root, and a timestamp. The hook does nothing unless that flag
  exists — so a **plain `/clear` never restores anything**.
- **SessionStart hook.** After a `/clear`, Claude Code fires a `SessionStart` hook
  with `source: "clear"`. The hook checks the flag and, if valid, injects the saved
  checkpoint as context (the "restore"), then deletes the flag. The injected context
  is model-only (not a visible chat message), so the restore also instructs the model
  to open its next reply with a visible `✓ Restored context via /context-cycle` line —
  otherwise a successful restore looks like "nothing happened."
- **One-shot.** Fires once, then disarms.
- **Project-scoped.** The flag records the repo root it was armed in. A `/clear` in
  a *different* project is ignored and **leaves the flag armed** for the right one.
- **Self-expiring.** A flag older than 1 hour is treated as stale and cleared, so a
  much-later `/clear` won't surprise-restore.

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
| `~/.claude/context-cycle/` | the armed flag + saved checkpoints |

It never modifies your code, and it doesn't phone home.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/androsland/claude-context-cycle/main/uninstall.sh | bash
# or, from a clone:  ./uninstall.sh
```

Removes the files and the settings entry (backing up `settings.json`). Saved
checkpoints are kept — delete them yourself if you want them gone.

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
