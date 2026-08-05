# Changelog

## v1.1.0 — 2026-08-05

Concurrency fix. Two sessions cycling at the same time could restore each other's
checkpoint — or lose one entirely. Both causes are fixed, and the machinery now has
a test suite.

- **Arm flags are one file per (project, session)**, under
  `~/.claude/context-cycle/armed.d/<project-hash>-<session-id>.json`, replacing the
  single machine-global `armed.json`. Two concurrent cycles can no longer clobber
  each other's pending restore. Re-arming from the *same* session still supersedes
  its own flag (newest checkpoint wins, no accumulation); a *different* session adds
  its own. A pre-existing `armed.json` is still read and consumed, so a cycle armed
  by the old version completes across the upgrade instead of stranding.
- **`.pending-file` is gone.** `arm.sh` previously fell back to reading the
  checkpoint path from a shared, machine-global scratch file. Step 2 — writing
  several KB of checkpoint prose — sits between that write and the read, and a second
  session's Step 1 landing in that window silently retargeted the first session's arm
  at the *second* session's checkpoint. The path is now a required argument, and
  `arm.sh` rejects an empty, whitespace-only, unexpanded-`$VAR`, relative, missing, or
  empty-file argument loudly (non-zero exit + a message naming the cause) instead of
  falling back to anything.
- **The hook now fails closed.** It previously fired when the `SessionStart` payload
  was missing or unparseable; a blind fire consumes an arm and injects stale context
  into an unrelated session. `source === "clear"` is now required — it is the only
  evidence a clear happened, since `/clear` mints a brand-new session id and the
  payload carries no link back to the pre-clear one.
- **Nested repos no longer match a parent's arm.** Subdirectory scope matching is kept
  (a `cd` during arming makes it load-bearing), but a subdirectory that is itself a
  repo boundary — a nested repo or submodule in a monorepo — is now correctly rejected.
- **Expired flags are swept on every session start**, so `armed.d/` cannot grow without
  bound on a machine where cycles get armed and abandoned. Unparseable flags are only
  reaped past the TTL, so a concurrent mid-write arm is never destroyed. Checkpoint
  files are still never written, moved, or deleted by the hook.
- **A symlinked state directory can no longer be used to delete files elsewhere.**
  The hook's sweep uses `readdirSync` + `unlinkSync`, which resolve through a
  symlink — so replacing `armed.d` with a link made the hook reap `*.json` out of
  the link's target instead. Both `armed.d` **and its parent `context-cycle/`** are
  now checked: a link at the parent is resolved by the OS during traversal, after
  which `armed.d` is a genuine directory and a leaf-only check passes. The hook
  treats either as "no arms"; `arm.sh` refuses to write through either.
  `~/.claude` itself is deliberately still allowed to be a symlink — pointing the
  config root at a dotfiles repo (stow, chezmoi) is a normal setup, and the hook
  resolves the root first so only the tool's own subdirectories are constrained.
  (`uninstall.sh`'s `rm -rf` was already safe here: `rm` unlinks a symlink without
  recursing into its target.)
- **The flag write no longer follows a symlink sitting on its path.** The temp file
  was named from the shell PID — sequential and guessable — and `cat >` follows an
  existing symlink, so a pre-placed `.tmp.<pid>.json` link would have `arm.sh` write
  the flag into whatever it pointed at. It now uses `mktemp`, which creates with
  `O_EXCL` and fails on a link rather than following it. The `cp` fallback (used only
  if `mv` fails) unlinks the destination first, since `cp` follows a destination
  symlink where `mv` does not, and the flag name is derived from public information.
- **Control characters in a path are rejected instead of silently breaking the flag.**
  A raw control byte in the checkpoint or project path produced invalid JSON, which
  failed *silently* — no restore, no error, until the TTL reaped it. `arm.sh` now
  fails loudly, with a control-byte strip in the JSON escaper as a backstop.
- **Test suite added** — `bash test/run-tests.sh`, 68 assertions across 17 groups,
  including a direct reproduction of the reported two-session bug, a hostile state
  dir (symlink at `armed.d`, at its parent, or on the flag path itself; control
  characters in paths), and a symlinked config root, which must keep working. Runs
  against a throwaway `CLAUDE_CONFIG_DIR`; needs only bash, node, and git.
- `uninstall.sh` now removes `armed.d/` as well as the pre-1.1 `armed.json` and
  `.pending-file`.

**Known limitation, documented rather than papered over:** with two armed sessions in
*one* project, the hook consumes the oldest matching flag. That is correct when they
clear in the order they armed and can mis-pair when they don't — the payload does not
say which session is clearing. The clear-time banner names the restored checkpoint, so
a mis-pair is visible instead of silent.

## v1.0.2 — 2026-07-10

- **Confirmation now shows at clear-time, and says what was restored.** v1.0.1 only
  instructed the model to print the ✓ line — but `/clear` does not invoke the model,
  so the line appeared only on the user's *next* message, leaving `/clear` itself
  silent. Two changes fix it properly:
  - The hook now emits a top-level **`systemMessage`**, which Claude Code renders to
    the user the instant `/clear` runs. It's enriched from the checkpoint, e.g.
    `✓ Restored: "auth refactor" · next: wire up the token rotation (feat/auth)`, so
    the banner shows *what* came back, not just *that* something did. Falls back to a
    plain line when the checkpoint isn't in the standard format.
  - The output is written with **synchronous `writeSync(1, …)`** instead of
    `process.stdout.write` + `process.exit()`. The old pattern could truncate a
    multi-KB checkpoint on the stdout pipe (buffer discarded before it drained),
    silently dropping the whole restore — the real cause of the "dead silence" some
    restores hit. `writeSync` guarantees the bytes land before exit.
- **Auto-recap on resume.** The injected context now asks the restored session to open
  its first reply with a 2–3 line recap (title + top remaining-work items), so picking
  up mid-task is visible, not silent. (Replaces v1.0.1's model-printed ✓ line, now
  redundant with the clear-time banner.)

## v1.0.1 — 2026-07-10

- Restore now emits a **visible confirmation line**. The `SessionStart` injection is
  model-only context, so a successful restore previously left no on-screen sign and
  looked like "nothing happened." The hook now instructs the model to open its next
  reply with `✓ Restored context via /context-cycle (branch: …)`, making the silent
  restore visible.

## v1.0.0

Initial release.

- `/context-cycle` skill: saves the working context to a checkpoint, arms a
  one-shot restore, and prompts for `/clear`.
- `SessionStart` restore hook: after an armed `/clear`, injects the saved
  checkpoint into the fresh session, then disarms.
- Project-scoped: a `/clear` in a different project won't consume the flag.
- One-shot with a 1-hour TTL on the armed flag.
- Standalone; auto-integrates with gstack's checkpoints when present.
- `install.sh` / `uninstall.sh` (idempotent, back up `settings.json`).
- Honors `CLAUDE_CONFIG_DIR`.
