# Changelog

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
