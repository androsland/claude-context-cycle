# TODOS

## Testing

- **The symlink-dependent groups never run on Windows.** That is groups 14a, 15, 16,
  17 and 19 in full, plus group 18's symlink-refusal half — six skips. Git Bash
  turns `ln -s` into a copy unless `MSYS=winsymlinks:nativestrict` is set, which
  needs Developer Mode or admin, so the suite's capability probe skips them there —
  reported by name, but skipped. The hostile-state guarding in
  `arm.sh` and the hook is therefore verified on Linux and macOS only; MSYS symlink
  semantics (does `lstat` on a Windows junction report a link?) are still untested.
  Group 19 is the one that stings: it is the regression guard for the path-form
  mismatch that Git Bash's 8.3 short names caused in the first place, and on Git Bash
  it cannot run. The real Windows coverage for that fix is the rest of the suite
  passing there, not group 19.
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
  (hooks/context-cycle-restore.mjs:174-183) treat the arm as unscoped, matching the
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

- **`install.sh`'s `.bak` symlink guard is check-then-use, like `arm.sh`'s.** The
  `[ -L "$dest.bak" ]` check runs before the file is fetched, and on the `curl | bash`
  path a network download sits between the check and the `cp` — stretching the window
  from a few local subprocess calls to however long the transfer takes. A second check
  immediately before the `cp` narrows it back to the local case (installed, mirroring
  `arm.sh:140-146`), but bash cannot close it: there is no way to open a path with
  `O_NOFOLLOW`, so a check and the subsequent `cp` are always two operations. Closing
  it properly means the same move as the `arm.sh` item above — doing the write from
  node, or a helper that can hold a directory fd. Same threat-model bound as every
  other item in this section: anyone who can plant that link can write
  `~/.claude/hooks/*.mjs` and get code execution outright. Note the second check has
  no dedicated assertion — group 18's `.bak` refusal is caught by the *first* check,
  and staging a link that appears only mid-download is not something the suite can do
  deterministically. It is correct by inspection and shares the first check's code
  path, which is weaker evidence than the rest of group 18 carries.
  (security review, 2026-08-06)

- **`install.sh` still installs through a symlink one level above what it guards.**
  It refuses a link at an installed file, at that file's `.bak`, and at the two
  directories it creates (`skills/context-cycle/`, `context-cycle/`) — but not at
  `~/.claude`, `~/.claude/skills` or `~/.claude/hooks`, so a link pre-placed at one
  of those makes `mkdir -p` resolve through it and every leaf `[ -L ]` read false.
  Deliberate, not an oversight: those three are Claude Code's, shared with every
  other skill and hook, and pointing them at a dotfiles repo (stow, chezmoi) is a
  normal setup that a refusal would break — the same line `arm.sh` and the restore
  hook already draw when they constrain `context-cycle/` and `armed.d/` but let
  `~/.claude` be a link. Bounded by the same threat model as the two items above:
  the content written is the fixed shipped bytes, and anyone who can pre-place that
  link can write `~/.claude/hooks/*.mjs` directly for outright code execution.
  Closing it properly means walking every ancestor up to `$CLAUDE_DIR` and asking
  the user per link, which is a worse trade than stating the limit.
  (security review, 2026-08-05)

- **The scope check's aliasing guard has a known false negative: reaching your
  project through a symlink that sits inside some *other* repo of your own.** The
  common shape is a `$HOME` that is itself a git repo (yadm, `git init ~`), but it is
  broader than that — any legitimate vendored or convenience symlink tracked in one of
  your repos and pointed at the project that happens to be armed trips it the same
  way. Canonicalizing the clearing cwd is what makes `/var` vs `/private/var` and
  Git Bash short names match, but on its own it lets *any* symlink alias into what it
  targets — a link inside repo B pointed at project A pulled A's checkpoint into a
  session working in B (reproduced; now blocked, and pinned by group 19). The check
  that separates the two is what the raw path walked *through*: a legitimate alias has
  no repository above it, a planted link does. A benign link inside a repo of your own
  is indistinguishable from a planted one by that test, so it gets no restore. Both
  conditions are needed (an enclosing repo *and* a symlink), the walk only runs when
  canonicalization actually moved the path, and the failure direction is conservative
  — but it is a silent non-restore, the exact class of bug this PR fixes elsewhere.
  A louder failure needs a channel the `SessionStart` hook does not have.
  **And it does not close aliasing in general — only the in-repo delivery vector.**
  A link with *no* repository above it (say `/tmp/foo` → the victim's project) still
  aliases through, verified. That is not closable: it is byte-for-byte the same
  situation as the macOS `/var` alias and as a user's own `~/dev/proj` symlink, which
  are the cases the canonicalization exists to serve. The vector that *is* closed is
  the realistic one — a symlink tracked in a repository you clone (git stores those
  as mode 120000 blobs) pointed at a guessable project path. Weigh the residual
  against what it yields: the content injected is the user's own checkpoint, and the
  session's cwd physically *is* the armed project, so the reader is the person who
  wrote it. (security review, 2026-08-05)

- **Portability of the symlink hardening: BSD now executed, MSYS still not.** The
  macOS CI job exercises BSD `mktemp` (`O_EXCL` creation) and BSD `find`'s
  non-following `-P` default against the real hostile-state groups, so those are no
  longer inferred from docs. Git Bash runs the suite but *skips* those groups (see
  Testing above), so MSYS2's `mktemp` and `find` remain unexercised on the paths
  that matter. (security review, 2026-08-05; partly closed by the CI work,
  2026-08-05)

## Restore semantics

- **A `/clear` inside a nested repo's *subdirectory* still matches the parent's arm.**
  `scopeAllows()` (hooks/context-cycle-restore.mjs:182) stats `.git` in the clearing
  cwd only, never the path between it and the armed root — so `repo/a/b/nested` is
  correctly rejected while `repo/a/b/nested/src` is not. Fix is walking up to the
  nearest repo boundary, at the cost of one stat per ancestor on every session start;
  deferred as not worth that on the common path. Documented as a blind spot in
  SKILL.md. The aliasing guard added alongside the path-canonicalization fix does
  exactly that walk, but only when the raw and canonical forms differ — so the cost
  objection above still stands for the common path, and this item is unchanged.
  (concurrency fix, 2026-08-05)
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
  installer idempotence and the four symlink refusals (destination, `.bak`,
  `settings.json.bak`, skill directory). (2026-08-05)
- **`test/run-tests.sh` no longer needs GNU tools.** `touch -d '3 hours ago'` is now
  a node `utimesSync` helper, and payload/config paths are converted to native form
  on Windows the way Claude Code sends them. (2026-08-05)
- **`arm.sh` no longer rewrites POSIX paths as Windows drive paths.** The MSYS
  `/c/` → `C:/` conversion ran unconditionally, so `/a/notes.md` was stored as
  `A:/notes.md` and the restore silently did nothing; it is now gated on actually
  running under MSYS/Cygwin. (2026-08-05)
- **`norm()`'s Windows accommodations are gated on Windows.** It lowercased every
  path, rewrote a single-letter first component to a drive path, and collapsed
  backslashes — all unconditionally. On a case-sensitive filesystem each merges paths
  that are genuinely different, and `scopeAllows()` then treats two unrelated projects
  as one: an arm taken in `~/Proj` was consumed by a `/clear` in a separate `~/proj`
  repo, no symlink involved. It also silently defeated the aliasing guard, since
  folding case made the raw and canonical forms compare equal so the divergence branch
  never ran. Pre-existing — byte-identical on `main` — but it lives inside the
  comparison this PR reworked and disabled part of it. Gating on `win32` leaves
  Windows unchanged. Group 20 pins it, skipped where the filesystem cannot host two
  such directories. (2026-08-06)
- **The test harness built its payload with `printf`, not `JSON.stringify`.**
  `clear_in()` interpolated the cwd straight into the JSON string, so a path
  containing a backslash or a quote produced a payload the hook could not match
  (`evil\repo` → a carriage return mid-path). It failed in the flattering
  direction: the assertion went green because the *fixture* was broken, not because
  the guard held, and it hid a real scope-check bypass during development until the
  payload was rebuilt properly. Claude Code serialises the payload, so the fixture
  now does too. (2026-08-06)
- **`rawEnclosingRepo()`'s backslash collapse is gated on Windows.** The aliasing
  guard walks the raw cwd up looking for the repo a planted symlink sits in, and it
  collapsed `\` to `/` unconditionally — the exact hazard `norm()` had just been
  fixed for, reintroduced in the one function whose job is to read a raw path. On
  POSIX a backslash is an ordinary filename character, so the collapse split one
  directory name into two, the walk stat'd `.git` under paths that do not exist, and
  returned "no repo above" — which the caller reads as allow. A repo named
  `evil\repo` holding a symlink to the armed project restored through it while the
  identical shape named `evilrepo` was blocked; reproduced both ways, and the two
  new group 19 assertions are the only ones that fail against the preceding commit.
  (security review, 2026-08-06)
- **The hook matches a project across path forms.** `arm.cwd` is git's *physical*
  path; the payload `cwd` may be *logical*. `scopeAllows()` now canonicalizes both
  before comparing, so `/private/var/…` vs `/var/…` on macOS and 8.3 vs long names
  under Git Bash no longer silently fail to restore. Found by CI — every restore
  assertion failed on macOS and Windows while Linux passed. Guarded by group 19,
  which reproduces the divergence with a symlink so it also runs on Linux.
  (2026-08-05)
