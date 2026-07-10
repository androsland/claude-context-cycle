# Changelog

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
