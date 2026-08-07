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
  it cannot run. The Windows coverage for that fix is the *rest* of the suite passing
  there — which it now does, 68/0/8 — not group 19.
  Closing it means a second Windows job with `nativestrict` enabled, which tests a
  configuration most users do not have — arguably the wrong thing to assert on.
  This entry used to also claim group 14b was permanently unrunnable on Windows
  because NTFS cannot hold `"` or a control byte in a filename. **That was wrong**:
  the probe creates `o\vd"d` fine under Git Bash and 14b passes on the Windows job.
  Nothing was broken by the mistake — the probe decides, and the probe was right —
  but a `uname` branch built on the same assumption would have skipped a group that
  works, silently. Worth remembering when the temptation is to hard-code a platform
  rather than ask it. (CI work, 2026-08-05; 14b claim corrected 2026-08-06)
- **Half of the staleness reconciliation is untestable in the suite.** The restore
  banner now reports the *older* of the flag's own `armed_at` and the inode's change
  time, so a flag stamped `now` can no longer read as fresh however long it has sat on
  disk. Group 8 pins one direction — an old `armed_at` on a freshly written flag must
  still report old, i.e. the `max()` must not have quietly replaced the field. The
  converse needs a flag whose *inode* is older than `STALE_AFTER` (4h), and ctime
  cannot be moved backwards by construction: the suite would have to wait four hours
  or move the system clock, neither of which belongs in a unit run. Reproducing it by
  hand costs a `sleep`, which is what it will take if that path ever regresses.
  (security review follow-up, 2026-08-07)
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
  **Update: removing the arm TTL widened this.** A planted flag used to self-destruct
  within an hour whether or not it was ever consumed; it now waits indefinitely for
  the next `/clear` in the project it names. The primitive is unchanged and the
  threat-model bound above still holds — this only removes a timer that happened to
  limit exposure, it does not create anything new — but it raises the value of the
  fix, because the window is now open-ended. Note the litter sweep does not close it:
  a *well-formed* attacker flag parses fine and is never litter. Second-order effect,
  same bound: with no TTL, `isLive()` no longer rejects an `armed_at` far outside the
  old ±3600s window, and candidates are sorted ascending by `armed_at`, so a planted
  flag stamped `0` deterministically wins the race against a legitimate concurrent arm
  in the same project instead of having to be timed. (2026-08-06)
  **Update: two of the three fields are now constrained; `checkpoint` is not.**
  `scopeAllows()` fails closed on a missing, empty or `/`-shaped `cwd` instead of
  matching every project, and `isLive()` rejects a non-positive `armed_at`, so the
  laziest forgery no longer sorts ahead of every real arm. Ten assertions in group 11b
  cover it, each verified to fail against the pre-change hook. **The recommended
  legacy-`armed.json` exemption was deliberately NOT implemented, and the
  recommendation was wrong** — v1.0.0's `arm.sh` wrote `cwd` from the same
  `git rev-parse --show-toplevel 2>/dev/null || pwd` line the current one uses, so it
  cannot produce an empty value and the exemption would have rescued nothing that
  exists. It would have restored the primitive outright: `armed.json` sits in the
  directory an attacker must already be able to write to. What is left open is the
  first field — `checkpoint` is still read verbatim from any absolute path — plus the
  fact that a forged flag with a *plausible* older `armed_at` still sorts first, which
  no shape check can catch. Both need the provenance check this entry is really about.
  Constraining `checkpoint` is blocked on a design question, not on effort: the hook
  knows only `$CLAUDE_DIR/context-cycle/checkpoints/$SLUG`, while `SKILL.md` also
  writes to `$GSTACK_STATE_ROOT/projects/$SLUG/checkpoints` when gstack is installed,
  and confining to the first silently breaks gstack users while teaching the hook the
  second means shelling out to a gstack binary — which the hook refuses to do on
  principle (see the "Reads `.git/HEAD` directly instead of shelling out" note above
  `currentBranch()` in hooks/context-cycle-restore.mjs; cited by name rather than line,
  because the first version of this entry cited a range that its own commit shifted).
  (2026-08-06)
  **Update: `checkpoint` is now constrained too; only the sort-order half is left.**
  The design question above was resolved by *deriving* gstack's root instead of asking
  for it — `GSTACK_HOME` → `CLAUDE_PLUGIN_DATA` (gated on `CLAUDE_PLUGIN_ROOT` naming
  gstack) → `~/.gstack` is pure environment logic with no subprocess in it, so the hook
  reimplements the chain rather than executing `gstack-paths`. `CONTEXT_CYCLE_CHECKPOINT_ROOTS`
  covers anything neither root reaches, and a refusal is loud and keeps the arm, so the
  escape hatch is reachable after the fact. Twenty assertions in group 22.
  **What is left of this entry:** a forged flag with a *plausible* older `armed_at`
  still sorts ahead of a legitimate concurrent arm, which no shape check can catch —
  and the arbitrary-read fix does **not** close prompt injection, because `armed.d/`
  and `checkpoints/` are siblings and whoever can write the flag can usually write the
  file it names. Both still want the provenance check this entry is really about.
  (2026-08-07)
  **Update: the sort-order half is closed; the provenance half is not, and this says
  why it probably never will be.** Candidate ordering no longer reads `armed_at` at
  all. It reads the inode's change time (`armOrder()`), which no POSIX call can set:
  there is no syscall for it, and it moves *forward* as a side effect of every metadata
  write — `touch -d 2020-01-01` and `utimesSync(0)` each leave mtime in the past and
  ctime at the current time. Measured on Linux, not read off a manual page. So a
  planted flag can no longer claim to predate an arm written before it, and the field
  is ignored rather than clamped, so a forgery cannot push itself later either. Eight
  assertions in group 23: three fail against the pre-change hook, and the remaining
  five are positive controls plus a deliberate limit-pin — the assertion that a flag
  planted BEFORE a real arm still wins, because this orders by write time and does not
  authenticate the writer.
  **The ordering alone did not hold, and the first version of this fix shipped with the
  hole open.** `statSync` and `readFileSync` both follow a symlink and report the
  target, so a symlinked entry in `armed.d/` grafts a fresh directory entry onto an
  inode the attacker last touched whenever they liked — the sort read the staged file's
  untouched ctime. Reproduced against the ordering fix: a flag staged outside
  `armed.d/`, then linked in two seconds *after* a legitimate arm, still sorted first
  and restored. An entry that is not a regular file is now refused with `lstat` at the
  single choke point the sweep and the candidate scan share, left on disk rather than
  deleted, and reported in the banner rather than skipped in silence. A hardlink is not
  refused and does not need to be — it is a regular file and `link()` moves the inode's
  ctime forward — which group 24 asserts rather than assumes. Six assertions in group
  24, five of which fail against the ordering-only hook. Found by the security reviewer
  on this branch's own diff and reproduced independently before acting on it.
  **Scope of that, narrower than the code looks:** "cannot be forged" means "not by any
  call that operates on the file", not absolutely — whoever serves the filesystem under
  `armed.d/` (a FUSE mount) or sets the system clock can state any ctime, both strictly
  stronger primitives than writing an arm flag and so inside this entry's own threat
  bound. ctime is also a POSIX property. Windows
  has no equivalent — libuv reports NTFS's ChangeTime, which the native API *can* set
  — so there this is ordering by write time rather than a guarantee about it, and it is
  untested on that platform. Ordering is also not a defence standing alone: losing the
  sort costs an attacker one cycle, since the flag stays on disk and is a candidate
  again at the next `/clear`. Group 23 asserts that too rather than leaving it implied.
  **What remains is the injection, and no check available to this hook reaches it.**
  Four shapes were weighed against this section's own threat model — an attacker
  running as the same uid with write access under `~/.claude`. A MAC over the flag
  needs a key stored where that attacker can read it. Ownership and mode are identical
  because the uid is identical. Binding to the arming session is impossible for the
  reason `arm.sh` already documents: `/clear` mints a new session id and the
  SessionStart payload carries no link back to the pre-clear one. A content digest in
  the flag is written by whoever writes the flag. The digest is the only one with any
  residue — it would bind the restored bytes to the arm on a *gstack* install
  specifically, where the checkpoint sits under `~/.gstack` and the flag under
  `~/.claude`, so write access to one tree is not write access to the other. Not taken
  here: an absent field is the downgrade, requiring the field strands arms in flight
  across an upgrade, and it buys a sha256 with a four-way portability fallback in shell
  for a gain confined to one install shape. Recorded as the only live idea, not as work
  queued. (2026-08-07)

- **`arm.sh` does not check the checkpoint root at arm time.** The hook refuses an
  out-of-root `checkpoint` on restore; `arm.sh` will still happily write the flag. So a
  user (or a skill variant) pointing `/context-cycle` at an unusual location gets a
  green arm and learns it was wrong only at the next `/clear`. Deliberate for now: the
  refusal is recoverable and duplicating the root derivation into shell means two
  implementations of the same policy drifting apart, which is a worse failure than a
  late warning. Revisit if the roots ever stop being derivable in one place.
  (checkpoint-confinement work, 2026-08-07)

- **The checkpoint read is still a check-then-use, though a much narrower one.** The
  hook reads the path `allowedCheckpoint()` *resolved*, not the string the flag gave
  it, so the obvious version of this is closed: a symlink inside a root cannot pass the
  check and then be re-pointed at `~/.ssh/id_rsa` before the read. What is left is
  replacing something at that resolved path between the check and the read — the file
  itself, which only yields attacker-authored content inside a root and so collapses
  into the already-accepted injection case, or a *directory component* of it, which
  could still escape. Both need write access to a checkpoint root, the same bound as
  the `[ -L ]` check-then-use below. Closing the remainder means an `open()`-then-
  `fstat()`-the-fd shape, or `O_NOFOLLOW` on each component. Note there is no
  deterministic test for any of this, closed part included: it needs the swap to land
  inside a window measured in microseconds. Group 22 asserts the observable half — a
  legitimate in-root link still restores — and nothing more.
  (checkpoint-confinement work, 2026-08-07; narrowed after security review the same day)

- **`safePath()` strips a named set of characters rather than allowlisting.** The
  refused path shown back to the user drops C0/C1 controls plus the zero-width and
  bidi-override ranges, which covers terminal escape injection and the
  render-as-a-path-it-is-not trick. It is not `safeRef()`'s allowlist, deliberately: a
  path the user has to *recognise* has to survive non-ASCII, and this string never
  reaches model context. The cost is that it is a blocklist, so a future Unicode
  display trick outside those ranges gets through to the terminal. Bounded to
  cosmetics — the message is already an anomaly banner. (security review, 2026-08-07)

- **The gstack root derivation is a copy of another project's private detail.** The
  hook reimplements `bin/gstack-paths`'s `GSTACK_STATE_ROOT` chain as read off gstack
  as installed on 2026-08-07. If gstack changes that chain, checkpoints written by the
  new gstack get refused, and nothing here will announce it — the failure surfaces as a
  user reporting a refusal, and the fix is `CONTEXT_CYCLE_CHECKPOINT_ROOTS` until the
  chain is updated. Accepted over the alternative (executing `gstack-paths` on the
  restore path) rather than because it is safe. gstack's relative `.gstack` fallback is
  intentionally not copied: a hook's cwd is not a trust anchor.
  (checkpoint-confinement work, 2026-08-07)

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
  Note the litter sweep is *not* part of this: `find` does not follow a symlinked start
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
  **Update: the `$HOME`-is-a-repo half is closed, and one new shape is admitted in its
  place.** The guard now asks whether the resolved cwd stayed *inside* the repository
  the raw path belongs to, rather than whether that repository *is* the armed project,
  so a convenience symlink under a repo-shaped `$HOME` pointed at a project *under* that
  `$HOME` restores instead of silently doing nothing. The broader half of this entry
  still stands: a link in one of your repos pointed at a project *outside* it is refused
  exactly as before, and group 19 pins that. What the relaxation admits is the hostile
  twin of the shape it fixes — a symlink shipped in a repo you clone, *sitting* under a
  directory that canonicalizes to an ancestor of the armed project, lands inside that
  ancestor and passes. Where it lives is what counts, not where it points, and the
  boundary is any entry named `.git`, real repository or not.
  Verified by running it, not reasoned about. Nothing distinguishes
  it from the benign case because they are one mechanism, and the tighter variant that
  does separate them costs a common working setup (see the Completed entry for what was
  measured and why it lost). Same bound as the rest of this section: the injected
  content is the user's own checkpoint and the cwd physically is the armed project.
  (2026-08-06)

- **Portability of the symlink hardening: BSD now executed, MSYS still not.** The
  macOS CI job exercises BSD `mktemp` (`O_EXCL` creation) and BSD `find`'s
  non-following `-P` default against the real hostile-state groups, so those are no
  longer inferred from docs. Git Bash runs the suite but *skips* those groups (see
  Testing above), so MSYS2's `mktemp` and `find` remain unexercised on the paths
  that matter. (security review, 2026-08-05; partly closed by the CI work,
  2026-08-05)

- **`safeRef()` stops structure, not spoofing.** Keeping `\p{L}`/`\p{N}` so a non-ASCII
  branch name stays readable also admits Unicode letters that render as something they
  are not — verified against the live regex: U+02CB MODIFIER LETTER GRAVE ACCENT (`Lm`,
  looks like a backtick) and U+3164 HANGUL FILLER (`Lo`, renders blank) both survive,
  while U+FF40 fullwidth grave, U+202E RTL override, U+200B zero-width space and a
  literal U+0060 are all replaced. So a branch name can still *look* wrong in the
  banner; it cannot close a code span, and JSON structure is never at risk because the
  whole payload goes through one `JSON.stringify`. Cosmetic spoofing only, deliberately
  not fixed: an ASCII-only allowlist would mangle every legitimate non-ASCII branch to
  buy a defence against a display trick that has no mechanism behind it.
  (security review, 2026-08-06)

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
- **Drift disclosure is silently unavailable inside a linked worktree or a submodule.**
  `currentBranch()` (hooks/context-cycle-restore.mjs) reads `.git/HEAD` directly and
  now returns `''` on a bare `.git` FILE rather than walking up — walking up reported
  the superproject's branch, which fabricated drift or hid it. Returning `''` is the
  safe direction (no line beats a wrong line) but it means someone who arms and clears
  in a worktree gets no drift warning at all, and nothing tells them the check was
  skipped. Fix is resolving the `gitdir:` pointer and reading HEAD there; deferred as
  a handful of extra lines on the restore path for a case that also needs an arm to
  have been made in that worktree. Age disclosure is unaffected.
  (security review, 2026-08-06)

## Completed

- **A project nested inside another repo now reaches its own arm, whatever form its
  path takes.** `scopeAllows()`'s aliasing guard asks what repository the RAW clearing
  path belongs to, and it used to demand that repository BE the armed project — false
  for every nested project, since a linked worktree, a submodule, or any repo checked
  out inside another has the OUTER repo above it as written. So wherever the raw and
  canonical forms diverged (a symlink anywhere in the prefix, macOS `/var`, a Windows
  8.3 short name) the outer repo was found, judged "not the armed project", and the arm
  refused. Silently, which is the class of defect this repo keeps finding. The armed and
  clearing cwd being the *identical string* did not save it: the old form never compared
  them. It now asks whether the resolved cwd stayed *inside* that repository — which is
  what the guard's own comment always claimed it did. Reproduced before it was touched:
  same fixture, same shell, same OS, `/tmp/link/proj/wt` refused and
  `/tmp/real/proj/wt` restored. Group 19b pins it with thirteen assertions; eight fail
  against the pre-change hook, though two of those eight fail only as fallout from the
  arms the earlier six leave unconsumed, so six is the honest count of assertions that
  encode the fix. The last three are aimed at something else — the containment-only
  intermediate this group was first written for, which the pre-change hook is not.
  Two of them fail against it; the third is a fresh-armed over-refusal guard that passes
  against every variant tried, and it is re-armed on purpose: sharing the arm with the
  line above it would have made it fail whenever *that* assertion failed, which reads
  like a third negative control while testing nothing of its own. Noticed in review.
  The `CAN_NESTED_SCOPE` probe is deleted and group 8e now runs
  on macOS and Windows rather than skipping itself there.
  **Two things this deliberately does not do.** It does not close the sibling item still
  open under Restore semantics — a `/clear` in a *subdirectory* of a nested repo still
  matches the parent's arm, which is a different check on a different line. Asking only
  for containment *would* have widened that item's reach, which the security review of
  this change caught and which is the part worth remembering: the fix's claim ("does not
  close it") was true while the fix itself made it reachable by more paths. Reproduced —
  armed at `main`, a separate repo at `main/vendor/subrepo`, `/clear` in `slink/src`
  where `slink` → that subrepo: refused before, restored after. A second condition
  (refuse when the raw path's repo sits strictly inside the armed project) restores the
  old boundary exactly, so this change is scope-neutral for that item. It does not close
  the gap on the direct path, so the two routes now disagree — `main/vendor/subrepo/src`
  still matches, `slink/src` does not — which is the pre-change behaviour, kept
  deliberately rather than taking half the sibling item by accident.
  And it accepts a residual: the guard can only ever be as strong as the nearest repo
  above the raw path, so where that repo canonicalizes to an ancestor of the armed
  project, any symlink *sitting* under it resolves inside it and passes. Where the link
  lives is what counts, not where it points, and the precondition is weaker than "you
  use yadm": `rawEnclosingRepo()` stops at any entry named `.git`, file or directory,
  real repository or not. Measured, not inferred. The benign shape — a
  user's own shortcut under a repo-shaped `$HOME`, which this now restores instead of
  silently refusing — is the same mechanism, so no check separates them. Refusing when
  the enclosing repo is *itself* a symlink does block the hostile half; that variant was
  built and measured, then rejected, because it silently breaks
  `ln -s /mnt/big/proj ~/proj` plus a `/clear` from any subdirectory of it, which works
  today. A silent non-restore on a setup that currently works is the worse trade.
  (2026-08-06)
- **shellcheck now runs in CI over every tracked shell script.** A `lint` job in
  `.github/workflows/test.yml`, ubuntu-only because static analysis returns the same
  verdict on every platform. Gated at full severity minus `SC2016` and `SC2012`, both
  excluded by name with their reasons in the workflow, rather than at
  `--severity=warning` — that tier looks stricter and is weaker, because `SC2086`
  (unquoted expansion) is classified *info*. Verified rather than assumed: a planted
  `rm -rf $f` fails the gate as configured and passes a warning-tier gate. The
  first-run backlog was 22 findings across two files — `install.sh` and `uninstall.sh`
  were already clean. Five were warnings and are fixed (`eq()` and one ternary rewritten
  to `if`/`else`, `arms()` and the temp-file count moved from `ls | grep -c` to globs,
  an unused capture dropped, `CONTEXT_CYCLE_TTL=` made explicit as `=''`); two
  deliberate idioms carry inline `# shellcheck disable=` with reasons at the site — the
  `2>&1 >/dev/null` stderr capture in group 7, and `tr 'a-z' 'A-Z'` on a drive letter in
  `arm.sh`. Suite unchanged at 128/0/0 before and after. **What it does not cover:** it
  has no rule for a TOCTOU window or a tautological capability probe, which is what the
  reviews of this repo have actually found — it does not retire the manual read, and the
  shell in `SKILL.md`'s fenced blocks is not linted by it. The runner's shellcheck is
  unpinned and can drift. (2026-08-06)
  **The gate is hardened against quiet tampering by the PR it is judging**, which the
  security review of this change caught and which matters because the job runs on
  `pull_request` over author-controlled files. shellcheck reads a `.shellcheckrc` found
  by walking up to the VCS root *by default*, so a PR could add one at the repo root
  disabling `SC2086` and turn its own lint green — reproduced, and closed with `--norc`.
  The flag-shaped-filename hazard is two coupled bugs, and the first pass described it
  wrongly — worth recording, since the fix looked complete and was not. As first
  written, a tracked file named `--exclude=SC2086` never reached shellcheck at all:
  `head -1 "$f"` in the shebang scan errored on the leading dash, the substitution came
  back empty, and the file fell out of the list — silently unlinted, job green. Adding
  `head -1 -- "$f"` lets it through, and only *then* does shellcheck parse it as an
  option: verified, exit 0 with a SIBLING script's real SC2086 unreported. Both
  separators are needed; either alone leaves a hole. Discovery is NUL-separated so a
  quoted path from `git ls-files` cannot reach the linter as a name that opens nothing.
  `persist-credentials` is off on the checkout: the job never pushes. Residual,
  accepted: the runner's shellcheck is unpinned, so its own supply chain is GitHub's
  image, not ours — and a fork PR can rewrite or delete the `lint:` job in its own copy
  of the workflow, which no flag on that job can prevent; the defence there is only
  that it shows up in the diff. (security review, 2026-08-06)
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
- **…and the Windows half needed a second fix, which the first one was claimed to
  cover.** `fs.realpathSync` resolves symlinks but does *not* expand an 8.3 short
  name; `fs.realpathSync.native` (`GetFinalPathNameByHandle`) does. So the entry
  above fixed macOS and left Git Bash failing the identical 19 assertions — same job,
  49 passed/19 failed at `b7efde1` and again at `7af86a0`, while macOS went 68/23 →
  101/2 over the same span. The short name was the right suspect; `realpathSync` was
  the wrong tool, and the shortfall was invisible because the diagnosis had been
  inferred from the macOS mechanism instead of measured on Windows. A permanent
  `Path forms` CI step now prints both variants on every platform, which is what
  settled it:

      git rev-parse --show-toplevel   C:/Users/runneradmin/AppData/Local/Temp/tmp.X
      payload cwd (cygpath -m)        C:/Users/RUNNER~1/AppData/Local/Temp/tmp.X
      fs.realpathSync                 C:\Users\RUNNER~1\...        <- still short
      fs.realpathSync.native          C:\Users\runneradmin\...

  `canon()` tries `.native` first, then the JS implementation, then the raw string.
  Confirmed green: Windows went 49/19/8 → **68 passed, 0 failed, 8 skipped**, and the
  same step on macOS shows both variants returning the identical `/private/var/…` for
  both input forms, so the switch is a measured no-op there rather than an assumed
  one. No test can cover this off Windows — no POSIX filesystem has a short name to
  expand — so that job is the whole of the evidence. (CI work, 2026-08-06)
