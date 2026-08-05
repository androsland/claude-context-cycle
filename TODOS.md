# TODOS

## Installer

- **`install.sh` overwrites `~/.claude` copies with a bare `cp`, with no check for
  local modifications.** `fetch()` (install.sh:27) copies straight over
  `$SKILL_DIR/SKILL.md`, `$SKILL_DIR/arm.sh`, and
  `$HOOKS_DIR/context-cycle-restore.mjs`. Anyone who patched an installed copy —
  which is exactly how the v1.1.0 concurrency fix was developed and tested — has it
  silently reverted by the next `install.sh` run, with no diff, no prompt, and no
  backup. Contrast with the settings.json merge a few lines below, which *does* back
  up before writing. Options: `cp` to `<file>.bak` first (matching the settings
  behaviour and the existing `*.bak` gitignore entry), or checksum against the
  shipped version and prompt when it differs. (concurrency fix, 2026-08-05)

## Testing

- **No CI runs `test/run-tests.sh`.** The suite is in-repo and dependency-free
  (bash + node + git), so a minimal GitHub Actions workflow on push/PR would catch a
  regression in the arm/restore contract before it ships. Nothing runs it today
  except a human remembering to. (concurrency fix, 2026-08-05)
- **`test/run-tests.sh` uses GNU-only `touch -d '3 hours ago'`** (groups 6, 14, 15) to
  age a file past the TTL. BSD `touch` on macOS has no `-d` in that form, so the
  suite's staleness assertions will not run there as written. Needs a portable
  helper (`touch -t` with a computed stamp, or a node one-liner using `utimesSync`).
  (concurrency fix, 2026-08-05)
- **Windows path handling is reasoned about but not exercised.** `arm.sh`'s
  `cygpath -m` / `/c/` → `C:/` conversion and the hook's `norm()` + `winPath()`
  win32 branch are only covered on POSIX, where the win32 branch is dead code. A
  Git Bash job in CI (or a `process.platform` shim in the suite) would close it.
  (concurrency fix, 2026-08-05)

## Security

- **An arm flag on disk is trusted wholesale — no provenance or integrity check.**
  Anything that can write `~/.claude/context-cycle/armed.d/*.json` (or the legacy
  `armed.json`) controls three fields the hook acts on unconditionally: `checkpoint`
  is read verbatim from *any* absolute path with no restriction to the checkpoints
  directory; an omitted or empty `cwd` makes `scopeAllows()`
  (hooks/context-cycle-restore.mjs:135-143) treat the arm as unscoped, matching the
  next `/clear` in any project; `armed_at` and `branch` are freely forgeable. The
  result is a prompt-injection primitive — attacker-chosen file content injected as
  `additionalContext` under the hook's own "resume from this, don't repeat it"
  framing. Not a regression: `git show main:hooks/context-cycle-restore.mjs` has the
  identical unchecked read and identical unscoped-when-no-cwd branch; v1.1.0 widens
  the surface from one file to many without hardening it. Bounded by the threat
  model — anyone with write access to `~/.claude/context-cycle/` can usually write
  `~/.claude/hooks/*.mjs` and get outright code execution, a strictly stronger
  primitive — so it matters mainly for a *narrower* compromise: a lower-trust skill,
  plugin, or MCP tool that can write under `~/.claude` but isn't expected to control
  agent context. Fix: resolve `checkpoint` and require it under the known checkpoints
  dir, and stop treating a missing `cwd` as match-everything except for the legacy
  `armed.json` migration path specifically. (security review, 2026-08-05)

## Restore semantics

- **A `/clear` inside a nested repo's *subdirectory* still matches the parent's arm.**
  `scopeAllows()` (hooks/context-cycle-restore.mjs:142) stats `.git` in the clearing
  cwd only, never the path between it and the armed root — so `repo/a/b/nested` is
  correctly rejected while `repo/a/b/nested/src` is not. Fix is walking up to the
  nearest repo boundary, at the cost of one stat per ancestor on every session start;
  deferred as not worth that on the common path. Documented as a blind spot in
  SKILL.md. (concurrency fix, 2026-08-05)
- **Two armed sessions in one project can mis-pair on out-of-order clears.** The
  hook consumes the oldest fresh arm matching the project; nothing in the
  `SessionStart` payload identifies which session is clearing, so it cannot do
  better today. Mitigated (not solved) by the clear-time banner naming the restored
  checkpoint, and documented as a known limitation in README.md and CHANGELOG.md.
  Revisit if Claude Code ever exposes a pre-clear session identifier to the
  `SessionStart` hook. (concurrency fix, 2026-08-05)

## Completed

- **Concurrency fix: per-(project, session) arm flags.** Replaced the single global
  `armed.json` with `armed.d/<project-hash>-<session-id>.json`, deleted the
  `.pending-file` fallback, made the hook fail closed on an unreadable payload, and
  added `test/run-tests.sh` (52 assertions). Shipped in v1.1.0. (2026-08-05)
