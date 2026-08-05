# TODOS

## Testing

- **The symlink-dependent groups (14a, 15, 16, 17) never run on Windows.** Git Bash
  turns `ln -s` into a copy unless `MSYS=winsymlinks:nativestrict` is set, which
  needs Developer Mode or admin, so the suite's capability probe skips those four
  groups there — reported by name, but skipped. The hostile-state guarding in
  `arm.sh` and the hook is therefore verified on Linux and macOS only; MSYS symlink
  semantics (does `lstat` on a Windows junction report a link?) are still untested.
  Closing it means a second Windows job with `nativestrict` enabled, which tests a
  configuration most users do not have — arguably the wrong thing to assert on.
  Group 14b is skipped there for a permanent reason, not a fixable one: NTFS cannot
  hold a filename containing `"` or a control byte. (CI work, 2026-08-05)
- **The `/a/notes.md` path-rewrite case is not reachable from CI.** The fix stops
  `arm.sh` mangling a checkpoint under a single-letter top-level directory into a
  Windows drive path, but asserting it needs a directory at the filesystem root,
  which the test suite cannot create without root and must not require. The
  regression guard that did land ("checkpoint stored verbatim") passes against the
  *pre-fix* code too — it locks the behaviour in going forward, it does not prove
  the fix. The mangling itself was reproduced directly (`sed -E
  's#^/([a-zA-Z])/#\U\1:/#'` on `/a/foo.md` yields `A:/foo.md` on GNU sed 4.8) and
  the consequence follows from group 12: an unreadable checkpoint path is treated
  as a vanished one and silently restores nothing. (CI work, 2026-08-05)

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

- **`arm.sh`'s symlink guard is a check-then-use, not an atomic one.** `[ -L ]` on
  `context-cycle/` and `armed.d/` runs at startup and again immediately before the
  write (arm.sh:43-50, 140-146), but `mkdir -p`, `git rev-parse`, `date`, and the hash
  subprocess all run in between, and the two `find`/`mv` calls after it re-use the
  same path strings. Someone who can write the parent directory can swap in a link
  inside that window. The second check narrows it to microseconds; bash has no atomic
  way to close it (no `openat`/`O_NOFOLLOW`), so closing it properly means moving the
  write into the node hook or a helper that can hold a directory fd. Same threat-model
  bound as the arm-flag-trust item above — write access to `~/.claude/context-cycle/`
  usually implies write access to `~/.claude/hooks/*.mjs`, which is strictly stronger.
  The `rm -f "$DEST"; cp -f "$TMP" "$DEST"` fallback (arm.sh:169) has a smaller
  instance of the same window — `$DEST` briefly does not exist between the two — but
  it replaces a *deterministic* symlink-follow with one an attacker must win a
  footrace to hit, and only on the branch taken when `mv` has already failed.
  Note the TTL sweep is *not* part of this: `find` does not follow a symlinked start
  point (POSIX default `-P`, verified on GNU findutils 4.8.0 and busybox find 1.30.1;
  BSD/macOS and Git Bash inferred from the same POSIX default, not executed).
  (security review, 2026-08-05)

- **Portability of the symlink hardening: BSD now executed, MSYS still not.** The
  macOS CI job exercises BSD `mktemp` (`O_EXCL` creation) and BSD `find`'s
  non-following `-P` default against the real hostile-state groups, so those are no
  longer inferred from docs. Git Bash runs the suite but *skips* those groups (see
  Testing above), so MSYS2's `mktemp` and `find` remain unexercised on the paths
  that matter. (security review, 2026-08-05; partly closed by the CI work,
  2026-08-05)

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
- **CI runs the suite on ubuntu, macOS and Git Bash** on every push and PR
  (`.github/workflows/test.yml`), with the toolchain implementations printed so a
  platform-only failure is diagnosable from the log. (2026-08-05)
- **`install.sh` backs up a locally modified file before overwriting it.** Differing
  destinations are copied to `<file>.bak` and named in the output; unchanged files
  are skipped so a no-op reinstall creates no backups, and each file keeps exactly
  one `.bak` so they cannot accumulate. Covered by test group 18, which also pins
  installer idempotence. (2026-08-05)
- **`test/run-tests.sh` no longer needs GNU tools.** `touch -d '3 hours ago'` is now
  a node `utimesSync` helper, and payload/config paths are converted to native form
  on Windows the way Claude Code sends them. (2026-08-05)
- **`arm.sh` no longer rewrites POSIX paths as Windows drive paths.** The MSYS
  `/c/` → `C:/` conversion ran unconditionally, so `/a/notes.md` was stored as
  `A:/notes.md` and the restore silently did nothing; it is now gated on actually
  running under MSYS/Cygwin. (2026-08-05)
