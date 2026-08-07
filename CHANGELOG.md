# Changelog

## Unreleased

Arms wait for you. Plus CI, and an installer that no longer eats your local edits.

- **A worktree, a submodule, or any project nested inside another repo now gets its
  restore back.** The scope check's aliasing guard asks which repository the clearing
  path belongs to *as written*, and it used to demand that repository **be** the armed
  project — which is never true for a nested one, since the outer repo sits above it.
  So wherever the path's raw and resolved forms differ (a symlink anywhere in the
  prefix, macOS `/var`, a Windows 8.3 short name) the outer repo was found, judged
  "not this project", and the arm refused. Silently — the `/clear` looked like any
  other, and the pending restore just never arrived. Being armed and cleared in the
  *identical* directory did not help; the old check never compared the two. It now asks
  whether the resolved path stayed **inside** that repository, which is what the guard
  was documented as doing all along. Reproduced before it was changed: same fixture,
  same shell, same machine — `/tmp/link/proj/wt` refused, `/tmp/real/proj/wt` restored.
  The same relaxation fixes a second silent refusal, a shortcut into your own project
  when `$HOME` is itself a git repo (yadm, `git init ~`). Group 19b pins both — and the
  neutrality below — with thirteen assertions, six of which fail against the code as it
  stood and two more against the half-finished version of this fix; group 8e no longer
  skips itself on macOS and Windows. **Not fixed
  here**, and still in `TODOS.md`: a `/clear` in a *subdirectory* of a nested repo
  continues to match the parent's arm — a different check entirely. Relaxing the guard
  alone would have made that gap reachable through a symlink as well, where the old form
  refused; a second condition holds the line, so the direct route still matches and the
  symlinked one still does not. Caught in review, reproduced both ways. **Accepted, and
  measured rather than assumed:** the check can only be as strong as the nearest repo
  above the path, so where that repo is an ancestor of your project, a symlink *sitting*
  under it resolves inside it and passes — where the link lives is what counts, not
  where it points, and the boundary is any entry named `.git`, real repository or not.
  The benign shortcut above is the same mechanism, so no check separates them. The
  tighter variant that does block it was built and tested, then rejected — it silently breaks
  `ln -s /mnt/big/proj ~/proj` plus a `/clear` from any subdirectory, which works today.
- **An arm flag with no project can no longer claim every project.** The hook treated
  a missing or empty `cwd` as "unscoped" and fired on the next `/clear` anywhere on the
  machine, injecting whatever file the flag named as model context under the hook's own
  "resume from this" framing. It now fails closed. Nothing legitimate is lost: every
  `arm.sh` ever shipped writes `git rev-parse --show-toplevel 2>/dev/null || pwd` into
  that field, which cannot come back empty — so an absent `cwd` was never a shape this
  tool produced. `"/"` is refused on the same path, since it normalises to empty. The
  legacy single-slot `armed.json` gets **no** exemption, which is a deliberate
  departure from what the security review recommended: the v1.0.0 writer emitted `cwd`
  from that same line, so an exemption would have rescued nothing real while handing
  the primitive back through a file in the directory an attacker already needs to
  write. A flag stamped `armed_at: 0` is also rejected now — arms sort ascending, so
  it used to beat every genuine arm in its project deterministically. That one has a
  cost worth naming: a machine whose clock is still at the epoch when you arm (dead
  RTC, no NTP yet) writes an honest flag that this discards, and the sweep then
  deletes it rather than skipping it. The checkpoint file survives; the pending
  restore does not. Ten new assertions, each checked to fail against the previous hook.
  The third field, `checkpoint`, is closed by the entry below. **Still open**, and
  recorded in `TODOS.md`: a forged flag carrying a *plausible* older timestamp still
  sorts first — not reachable by a shape check, and needing the provenance check.
- **A restore no longer reads whatever file the arm flag names.** `checkpoint` was
  taken verbatim from any absolute path and its contents injected as model context
  under the hook's own "resume from this, don't repeat it" framing — an
  arbitrary-file-**read** primitive for anything that could write into
  `~/.claude/context-cycle/armed.d/`. The hook now accepts a checkpoint only under
  `~/.claude/context-cycle/checkpoints`, under gstack's `<state-root>/projects` — the
  two places the skill actually writes — or under anything listed in
  `CONTEXT_CYCLE_CHECKPOINT_ROOTS` (`PATH`-style: `:` on Unix, `;` on Windows). Both
  sides are resolved before comparing, so a symlinked `~/.claude` (stow, chezmoi)
  matches and a symlink *inside* a root that points out of it does not; the boundary
  is `=== root || startsWith(root + '/')`, so a sibling named `<root>-evil` is out.
  The file is then read from the **resolved** path rather than the string the flag
  gave, so a link that passed the check cannot be re-pointed at `~/.ssh/id_rsa` before
  the read. That does not make the read atomic, and the residue is not all one thing:
  swapping the *file* at the resolved path only yields attacker-authored content
  inside a root, which is the injection case already accepted above — but swapping a
  *directory component* of it in the same window can still escape every root, which is
  this same arbitrary read behind a race rather than in the open. Both need write
  access to a checkpoint root. Open, with the `O_NOFOLLOW`/`fstat` shape that closes
  it, in `TODOS.md`; there is no deterministic test for either.
  **A refusal keeps the arm.** It is announced on its own and, when a later arm does
  restore, appended to that banner — so a mis-derived root costs one env var and a
  second `/clear`, never the checkpoint. That is the whole reason this could ship on by
  default: the project had already rejected a silent non-restore on a working setup,
  and this converts it into a visible, reversible one. gstack's root is **derived**,
  not asked for: its `GSTACK_HOME` → `CLAUDE_PLUGIN_DATA` (only when `CLAUDE_PLUGIN_ROOT`
  names gstack) → `~/.gstack` chain is pure environment logic, so it is reimplemented in
  six lines rather than executing `gstack-paths`, which the hook declines to do on the
  restore path for the same reason it reads `.git/HEAD` instead of running `git`.
  gstack's relative `.gstack` fallback is deliberately dropped — a hook's cwd is not a
  trust anchor. Existence is checked before policy, so a checkpoint that is simply gone
  still falls through to the sweep instead of becoming a permanent refusal. Twenty
  assertions in a new group 22; the rest of the suite moved onto the real checkpoints
  directory to test the policy rather than an exemption, closing a fidelity gap that
  predates it — nothing had ever armed from a path the skill would produce. Against the
  hook as it stood, twelve of the twenty fail because it restored what it should have
  refused and three more because the arm did not survive to be recovered; three pass
  there vacuously (they assert an arm count or an absent injection, which a hook that
  already consumed the flag satisfies for the wrong reason) and two are positive
  controls that must pass on both. **What this does not close, and must not be read as
  closing:** prompt injection. `armed.d/` and `checkpoints/` are siblings, so whoever
  can plant the flag can almost always plant the file it points at. This narrows what
  can be injected, not whether — that still needs the provenance check in `TODOS.md`.
- **A planted arm flag can no longer jump the queue by claiming to be old.** When two
  arms match the same project the hook consumes the oldest, and "oldest" was read out
  of the flag's own `armed_at` — a field written by whoever wrote the flag. So a
  planted one backdated by a minute sorted ahead of every legitimate arm in that
  project and won every `/clear` outright, rather than having to win a race it might
  lose. The earlier `armed_at > 0` check only removed the laziest spelling: `1` worked
  exactly as well as `0`. Ordering now runs on the inode's change time, which no POSIX
  call can set — there is no syscall for it, and it moves *forward* as a side effect of
  every metadata write, so `touch -d 2020-01-01` and a `utimes()` to the epoch each
  leave mtime in the past and ctime at the current time. Measured, not read off a
  manual page. `armed_at` is now ignored for ordering rather than clamped, so a forgery
  cannot push itself later either, and nothing in the comparator reads a field the flag
  supplied. Eight assertions in a new group 23, three of which fail against the hook as
  it stood. **The ordering alone was not enough, and the first version of this change
  shipped with the hole open.** `statSync` and `readFileSync` both *follow* a symlink
  and report the target, so a symlinked entry in `armed.d/` grafts a fresh directory
  entry onto an inode the attacker last touched whenever they liked — no race, no
  backdating, and the sort read the staged file's untouched ctime. Reproduced against
  the ordering fix itself: a flag staged outside `armed.d/`, then linked in two seconds
  *after* a legitimate arm, still sorted first and restored the planted checkpoint. An
  entry that is not a regular file is now refused before anything reads it, checked
  with `lstat` at the one place both the sweep and the candidate scan go through.
  Refused rather than ordered by the link's own ctime: nothing legitimate makes an arm
  flag a link, and this file already refuses a symlinked `context-cycle/` or `armed.d/`
  one level up. A refused entry is left on disk — the hook does not delete what it
  declines to read — and is **reported in the banner**, because a silent non-restore on
  a setup that works is the failure this project keeps finding. A hardlink is *not*
  refused and does not need to be: it is a regular file, and `link()` is a metadata
  write that moves the inode's ctime forward, which group 24 asserts rather than
  assumes. Six assertions in a new group 24, five of which fail against the
  ordering-only hook. **The `lstat` on its own was still a check-then-use**, and that
  went too: classifying by path and then reading by path left a window to swap the
  entry through, so every candidate is now opened once with `O_NOFOLLOW` and the
  regular-file check, the sort key and the content all come off that one descriptor.
  The window was *not* demonstrated — a toggle loop at ~700 cycles/s won 0 of 400
  clears against the pre-fix hook — and it went in on the shape of the code path
  rather than on a reproduction, because it costs one syscall. `O_NOFOLLOW` is POSIX;
  Node reports it undefined on Windows, the same platform where ctime is not a
  guarantee either.
  The staleness disclosure was re-coupled to the same clock in the same pass: it read
  `armed_at` while ordering read ctime, so a flag stamped `now` read as fresh however
  long it had sat there. Age is now the *older* of the two, which also fixes an honest
  case — a flag written while the machine's clock was wrong now reports its real age.
  **Two limits, asserted rather than described.** This orders by *when* a
  flag was written and does not authenticate *who* wrote it, so a flag planted before a
  real arm genuinely is older and still sorts first. And ordering is not a defence on
  its own: losing the sort costs an attacker one cycle, because the flag stays on disk
  and is a candidate again at the next `/clear`. **And a scope note:** "cannot be
  forged" means "not by any call that operates on the file" — whoever serves the
  filesystem under `armed.d/` or sets the system clock can still state any ctime, both
  strictly stronger primitives than writing an arm flag and so inside the same threat
  bound. ctime is also a POSIX
  property; Windows has no equivalent — libuv reports NTFS's ChangeTime, which the
  native API can set — so there this is ordering by write time rather than a guarantee
  about it, and it is untested on that platform. The other half of the arm-flag trust
  problem, injection, is unchanged and stays in `TODOS.md`, which now also records why
  a provenance check is unlikely to arrive.
- **`./install.sh` actually runs now.** Both `install.sh` and `uninstall.sh` shipped
  tracked as `100644`, so the README's own clone path — `./install.sh` — failed with
  `Permission denied` on the very first step. The `curl | bash` route pipes into an
  interpreter and never needs the bit, which is why it went unnoticed. Both are
  `100755` now, and the suite asserts the tracked mode so a future `git add` of a
  freshly-created script cannot quietly reintroduce it. `arm.sh` stays `100644`
  deliberately: `SKILL.md` invokes it as `bash arm.sh`.
- **An armed restore no longer expires.** It used to die after an hour. That meant
  `/context-cycle`, lunch, `/clear` — and the context was gone, with nothing said
  about why: the arm had been swept, so the clear looked like any other clear and the
  fresh session had no idea a restore had ever been pending. Closing the editor and
  picking the work up the next day, which is the ordinary way to use this, lost the
  restore every time. An arm now lives until it is consumed or its checkpoint file
  disappears. `CONTEXT_CYCLE_TTL=<seconds>` puts a bound back for anyone who wants
  one; unset, blank, `0` and junk all mean no bound.
- **The same expiry lived in a second place, and it was the worse one.** `arm.sh`
  swept `armed.d/*.json` older than 60 minutes on every run, and `armed.d/` is shared
  across every project — so arming a cycle in one project silently deleted another
  project's pending restore. Its sweep now only collects abandoned `.tmp.*` files.
  Corrupt-flag collection moved to the hook, which can actually parse a flag and tell
  litter from a live arm; both now use a 7-day litter horizon, deliberately a
  different clock from an arm's lifetime rather than the same constant doing two jobs.
- **A restore that is out of date now says so.** Since an arm can be days old, the
  banner reports the checkpoint's age past 4 hours, and if the branch has changed
  since it was saved, both the banner and the injected context say which branch it was
  written on and which one you are on now — with an explicit instruction to re-check
  the "Remaining Work" items rather than resume them on faith. This is the mitigation
  for the one thing the TTL was genuinely buying: a forgotten arm being consumed by an
  unrelated `/clear` much later. It is disclosure, not prevention, and `SKILL.md`'s
  known-limits section says so.
- **Branch names are treated as untrusted before they reach the model.** The drift
  disclosure above put a branch name into the injected context inside a code span, and
  git permits a backtick in a ref — so reviewing a fork's PR branch, then clearing,
  could close that span and inject text into a header the model is told to resume
  from. Unlike everything else the hook reads, that needs no write access to
  `~/.claude`. Branch names from both `.git/HEAD` and the arm flag now keep only
  letters, digits and ref punctuation; anything else becomes `?`. Drift itself is still
  decided on the raw names, so two that sanitize alike still count as different.
- **A worktree or submodule no longer reports its parent's branch.** `.git` there is a
  file, not a directory; the branch lookup used to walk past it and report the
  superproject's branch as the current one, which invented drift or hid it. It now
  reports nothing, which is the honest answer — noted as a limitation in `TODOS.md`.

- **The test suite runs in CI** on ubuntu, macOS and Windows (Git Bash), on every
  push and pull request. Nothing ran it before except a human remembering to.
- **And the shell is linted there now.** Shell is most of this repo's executable
  surface — four scripts that run with your privileges and write into `~/.claude` —
  and CI only ever *ran* them. A `shellcheck` job now reads every tracked shell script
  on every push and pull request. It is gated at full severity minus two rules
  excluded by name in the workflow, not at `--severity=warning`: that tier reads as
  stricter but is weaker, because unquoted expansion (`SC2086`) is classified *info*
  and would sail through it — confirmed by planting an unquoted `rm -rf $f` and
  watching each gate. The first run found 22 things across two files; `install.sh` and
  `uninstall.sh` were already clean. All are resolved, the deliberate ones with an
  inline `# shellcheck disable=` carrying its reason at the site. Discovery is by
  shebang as well as by `*.sh`, so a future script named without the extension cannot
  ship unlinted while the job still reports success. No behaviour changed: the suite
  reads 128 passed, 0 failed either side of it. It does not replace the manual
  security reads — shellcheck has no rule for a check-then-use window, which is what
  those reads have actually been finding.
- **And the lint job gives the pull request it is judging no quiet way to switch it
  off.** A gate that runs on `pull_request` reads files the PR author wrote, so two of
  shellcheck's own defaults were exploitable and both were reproduced before being
  closed. shellcheck discovers a `.shellcheckrc` by walking up to the VCS root by
  default, so a PR adding a repo-root `.shellcheckrc` with `disable=SC2086` next to a
  change to `arm.sh` turned the job green while shipping an unquoted expansion —
  `--norc` now. And a filename that looks like a flag is parsed as one, in two places
  that only bite in sequence: `head`, reading the shebang, errors on a name starting
  with `-` and the file drops out of the list unlinted; once `head --` lets it through,
  shellcheck consumes a file named exactly `--exclude=SC2086` as an *option* and exits
  0 with a *sibling* script's real finding unreported. Both take `--` now. Discovery is
  NUL-separated for the same family of reason, since `git ls-files` quotes a path
  containing a newline instead of emitting it raw. Verified against a real shellcheck,
  before and after. Not covered, because it cannot be: a fork PR edits its own copy of
  the workflow, so weakening or deleting the job outright stays available — that is
  visible in the diff, which is the difference.
- **`install.sh` refuses to install through a symlink — at the file, at its `.bak`,
  or at the directory above it.** `cp` resolves a link in both directions: the new
  backup step would copy the link *target's* contents out to a predictable `.bak`
  path, and the install itself would write the shipped file straight through the
  link into that target — the second of which the bare `cp` had been doing all
  along. The `.bak` name needs the same guard and is the worse of the two: `cp`
  follows a link at its *destination* as well, so a link pre-placed at the entirely
  predictable `<file>.bak` makes the backup write the installed file's current
  contents into whatever it points at — and that branch fires on every upgrade
  where the installed file differs, not on some rare edge case. `settings.json.bak`
  had the identical hazard via node's `copyFileSync`. And because `[ -L ]` on a file
  cannot see a link on the path *leading* to it — `mkdir -p` resolves a symlinked
  directory and succeeds — the two directories this tool creates
  (`skills/context-cycle/`, `context-cycle/`) are now checked before they are made.
  All four reproduced. The installer stops with a message naming the link rather
  than unlinking it silently: pointing an installed file at a local checkout is a
  real dev setup, and quietly replacing the link with a copy would break it with no
  way to notice. `~/.claude` itself, `~/.claude/skills` and `~/.claude/hooks` are
  deliberately still allowed to be links — they are Claude Code's, shared with every
  other skill, and pointing them at a dotfiles repo is normal.
- **`install.sh` backs up a modified file before overwriting it.** It used to `cp`
  straight over an installed copy — no diff, no prompt, no way back — which silently
  reverted anyone who had patched their install. Now a destination that differs from
  the shipped version is copied to `<file>.bak` first and the overwrite is named in
  the output. Unchanged files are left alone, so a no-op reinstall creates no
  backups, and each file keeps exactly one `.bak` (overwritten each run) so they
  cannot pile up. Matches how `settings.json` was already handled.
- **A project armed under one form of its path is now restored under any other.**
  `arm.sh` records the project from `git rev-parse --show-toplevel`, which returns the
  *physical* path, while the `SessionStart` payload carries whatever the session was
  launched in, which may be *logical*. Those name the same directory and the hook
  compared them as strings, so they missed: on macOS a repo under `/tmp` or `/var` is
  `/private/…` to git and `/…` to the shell. The failure was silent — the arm simply
  never matched, the restore did nothing, and the flag sat there until the TTL reaped
  it. Both sides are now resolved to a canonical path before comparison, falling back
  to the raw string when a path cannot be resolved. Found by the new CI: every restore
  assertion failed on macOS and Windows while Linux passed, because on Linux the two
  forms happen to be identical. Windows then needed a *second* fix on top:
  `fs.realpathSync` resolves symlinks but does not expand an 8.3 short name, so
  canonicalizing alone took macOS from 23 failures to 2 (both unrelated) and left Git
  Bash failing the identical 19 assertions before and after. `fs.realpathSync.native`
  — `GetFinalPathNameByHandle` — does expand it, and is now tried first; the Windows
  job went to 68 passed, 0 failed. A `Path forms` CI step prints both variants on
  every platform, because the short-name diagnosis was originally *inferred* from the
  macOS mechanism rather than measured, and was wrong about which call fixed it.
  Resolving paths is a widening on its own — *any* symlink on the clearing cwd would
  alias into whatever it targets, so a link planted inside repo B and pointed at
  project A pulled A's checkpoint into a session working in B. Narrowed by the one
  thing that separates the two: what the raw path walked *through*. A `/var` alias, a
  short name, or a plain symlink to a project has no repository above it; a planted
  link does, and it isn't the repo we landed in. That walk collapses backslashes only
  on Windows, where a backslash is a separator — doing it on POSIX, where it is an
  ordinary filename character, split one directory name into two, so the walk looked
  for `.git` under paths that do not exist, found no repo above the link, and allowed
  the restore. Naming the attacking repo `evil\repo` was the whole bypass. Both sides
  are pinned by tests.
- **Two projects whose paths differ only in case are two projects again.** The scope
  check lowercased every path, rewrote a single-letter first component to a drive
  path, and collapsed backslashes — all unconditionally, though all three exist only
  to make Windows paths compare correctly. On Linux, or a case-sensitive macOS volume,
  that merged genuinely different directories: an arm taken in `~/Proj` was consumed
  by a `/clear` in a separate `~/proj`, with no symlink involved. It also quietly
  defeated the symlink-aliasing guard above, since folding case made the raw and
  resolved forms compare equal so that check never ran. Now gated on actually running
  on Windows, where behaviour is unchanged.
- **`arm.sh` no longer rewrites POSIX paths as Windows drive paths.** The MSYS
  `/c/…` → `C:/…` conversion ran unconditionally, so a checkpoint under any
  single-letter top-level directory (`/a/notes.md`) was stored as `A:/notes.md` — a
  path the hook cannot read, making the restore silently do nothing. It is now gated
  on actually running under MSYS/Cygwin. The old expression also used `\U`, a GNU sed
  extension BSD sed does not implement, so on macOS it was wrong in a second way.
- **The suite is portable.** `touch -d '3 hours ago'` (GNU-only) is replaced by a
  node `utimesSync` helper, and payload/config paths are converted to native form on
  Windows the way Claude Code itself sends them. What a filesystem can host is
  *probed* rather than assumed from `uname` — real symlinks, `"` and control bytes in
  a name, case sensitivity, a literal backslash in a name — and a group whose
  prerequisite is missing is skipped by name, with the reason and a summary count,
  rather than quietly passing. Probing earned its keep immediately: the group needing
  `"` and control bytes was assumed unrunnable on Windows and in fact passes there.
  Green on all three: 106 passed on ubuntu, 103 with 1 skip on macOS, 68 with 8 skips
  on Git Bash (six of them symlink-dependent).

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
