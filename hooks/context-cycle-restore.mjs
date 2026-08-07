#!/usr/bin/env node
// SessionStart hook for the /context-cycle skill.
//
// Fires only when ALL of these hold:
//   (a) the payload says source === 'clear' (strict — see "fails closed" below),
//   (b) an "armed" flag written by /context-cycle exists and is still live,
//   (c) the current project matches the one that flag was armed in.
// On fire: show the user a clear-time confirmation (systemMessage) AND inject the
// saved checkpoint into the model's context (additionalContext) — that injection
// IS the restore — then delete THAT ONE flag (strictly one-shot).
//
// Concurrency: arms live one file per (project, session) under context-cycle/
// armed.d/, so two sessions cycling at the same time cannot overwrite each
// other's pending restore. This hook consumes the OLDEST fresh arm matching the
// cleared project and leaves the rest armed. A pre-existing single-slot
// context-cycle/armed.json (the older layout) is still read and consumed, so a
// cycle armed by the old arm.sh completes instead of stranding.
//
// Fails closed: /clear mints a brand-new session id and the payload carries no
// link to the pre-clear session, so 'source' is the only evidence that a clear
// actually happened. A missing or unreadable payload therefore does NOT fire —
// firing blind would consume an arm on an unrelated session start and inject a
// checkpoint nobody asked for.
//
// Only arm flags are ever deleted here. Checkpoint files are append-only: this
// hook never writes, moves, or removes one.

import { readFileSync, readdirSync, statSync, lstatSync, realpathSync, existsSync, unlinkSync, writeSync,
         openSync, closeSync, fstatSync, constants } from 'node:fs';
import { homedir } from 'node:os';
import { join, delimiter, isAbsolute, normalize } from 'node:path';

// An arm does not expire by age. It lives until it is consumed, or until the
// checkpoint it points at is gone. Closing the editor on Friday and clearing on
// Monday has to restore exactly as it would have a minute later — that is the whole
// point of the feature, and the old 3600s bound quietly defeated it: the arm was
// swept, the /clear looked like any other, and nothing told the user why their
// context did not come back.
//
// Set CONTEXT_CYCLE_TTL to a positive number of seconds to put the bound back, for
// anyone who would rather a forgotten arm self-destruct than wait indefinitely.
// Unset, blank, zero, negative and unparseable all mean "never expires" — the
// default. When it IS set the comparison is the old two-sided one, so opting in
// reproduces the previous behaviour exactly rather than something new.
const armTtlRaw = Number((process.env.CONTEXT_CYCLE_TTL || '').trim());
const ARM_TTL_SECONDS = Number.isFinite(armTtlRaw) && armTtlRaw > 0 ? armTtlRaw : 0;

// Litter collection, on its own clock and deliberately NOT the same concept as arm
// liveness. sweep() may only delete a flag it cannot parse — which is also what a
// concurrent arm.sh mid-write looks like — so it has to wait out any plausible write
// window first; same for abandoned .tmp.* files. That job still has to happen now
// that arms themselves never age out, or armed.d/ grows without bound on a machine
// where writes get interrupted. Seven days is far past any write window and far
// short of "I was on holiday".
const LITTER_TTL_SECONDS = 604800;

// Resolve the config root to its physical path before building anything under it.
// ~/.claude is often a symlink into a dotfiles repo (stow, chezmoi) — legitimate,
// and deliberately still allowed. The directories BELOW it are the ones that must
// be real; see armDirUsable().
const claudeDirRaw = (process.env.CLAUDE_CONFIG_DIR || '').trim() || join(homedir(), '.claude');
let claudeDir = claudeDirRaw;
try { claudeDir = realpathSync(claudeDirRaw); } catch { /* not created yet */ }
const stateDir = join(claudeDir, 'context-cycle');
const armDir = join(stateDir, 'armed.d');
const legacyArmedPath = join(stateDir, 'armed.json');

function noop() { process.exit(0); }                 // no stdout => nothing injected

// Normalize a path for cross-tool comparison. Everything except dropping a trailing
// slash is a Windows accommodation and is gated on actually running there.
//
// Ungated, all three transforms merge paths that are genuinely different on a
// case-sensitive filesystem, and `scopeAllows()` then treats two unrelated projects
// as one: lowercasing makes ~/Proj and ~/proj compare equal, the MSYS rewrite makes
// /a/x and /A/x both become 'a:/x', and collapsing backslashes makes 'a\b' and 'a/b'
// equal where a backslash is a legal filename character. Reproduced: an arm taken in
// ~/Proj was consumed by a /clear in a separate ~/proj repo with no symlink involved.
// It also silently defeated the aliasing guard below, because folding case made the
// raw and canonical forms compare equal, so the divergence branch never ran.
//
// Pre-existing (identical on main) rather than introduced by the canonicalization
// work, but it lives in the same comparison and disables part of it, so it is fixed
// here. Gating on win32 leaves Windows byte-for-byte unchanged.
const IS_WIN = process.platform === 'win32';
function norm(p) {
  if (!p) return '';
  let s = String(p);
  if (IS_WIN) {
    s = s.replace(/\\/g, '/');
    const m = /^\/([a-zA-Z])\/(.*)$/.exec(s);
    if (m) s = m[1] + ':/' + m[2];
  }
  s = s.replace(/\/+$/, '');
  return IS_WIN ? s.toLowerCase() : s;
}

// Clamp to n chars with an ellipsis (for the one-line banner).
function clamp(s, n) {
  s = String(s);
  return s.length > n ? s.slice(0, n - 1).replace(/\s+$/, '') + '…' : s;
}

// Branch names are interpolated into the model-facing header, and a branch name is NOT
// trusted input: checking out a fork's PR branch to review it is routine, and git
// accepts a backtick in a ref (only ~^:?*[ , control chars, and a few structural rules
// are rejected — verified: `git checkout -b 'fix`x`y'` succeeds and lands verbatim in
// .git/HEAD). Unescaped, such a name closes the code span it sits in, and the header's
// "resume from this, do not repeat work already marked done" framing is exactly what
// makes that worth doing. Note this needs no write access to ~/.claude, so it is NOT
// covered by the arm-flag trust boundary the rest of this file accepts.
//
// Keep letters and digits — \p{L}/\p{N}, so a non-ASCII branch stays readable — plus
// the punctuation refs actually use. Everything else becomes '?'. Display only: drift
// is decided on the RAW values, so two names that sanitize alike still count as drift.
function safeRef(s) {
  // '…' is allowed through because clamp() runs first and appends one; it is inert.
  return String(s || '').replace(/[^\p{L}\p{N}._\/+@…-]/gu, '?');
}

// Best-effort parse of the /context-cycle checkpoint markdown (see the skill's
// Step 2 template): pull "## Working on: <title>" and the first item under
// "### Remaining Work". Returns '' for anything it can't find, so callers degrade.
function parseCheckpoint(md) {
  let title = '', nextStep = '', inRemaining = false;
  for (const line of String(md).split(/\r?\n/)) {
    const t = /^##\s+Working on:\s*(.+?)\s*$/.exec(line);
    if (t) { title = t[1].trim(); continue; }
    if (/^###\s+Remaining Work\s*$/i.test(line)) { inRemaining = true; continue; }
    if (inRemaining && !nextStep) {
      if (/^###\s/.test(line)) break;                        // hit the next section
      const li = /^\s*(?:\d+[.)]|[-*])\s+(.+?)\s*$/.exec(line);
      if (li) nextStep = li[1].trim();
      else if (line.trim()) nextStep = line.trim();          // prose fallback
    }
  }
  return { title, nextStep };
}

// readdirSync + unlinkSync(join(armDir, name)) resolve through a symlink, so a
// link swapped in for one of these directories makes this hook enumerate and
// DELETE *.json out of whatever it points at. Checking only armed.d is not enough:
// the OS resolves a symlinked PARENT during traversal, after which armed.d itself
// is a perfectly real directory and the leaf check passes. So both levels below
// the (already resolved) config root must be real directories. Anything else is
// treated as "no arms" — never read through, never unlinked through.
// (uninstall.sh's `rm -rf` is safe by contrast: rm removes a symlink without
// recursing into its target.)
function realDir(p) {
  try { return lstatSync(p).isDirectory(); } catch { return false; }
}
function stateDirUsable() { return realDir(stateDir); }
function armDirUsable() { return realDir(stateDir) && realDir(armDir); }

// Every arm-flag file on disk: the per-(project, session) files plus a legacy
// single-slot armed.json if one is still lying around. Split into the ones that are
// REGULAR FILES and the ones that are not, because a link here is not a flag.
//
// A path-based read of either the content or the ctime follows a symlink and reports
// the TARGET. So a symlinked entry grafts a fresh directory entry onto an inode the
// attacker touched at a time of their choosing, which is exactly the forgery the ctime
// ordering exists to stop — and it needs no race and no backdating. Reproduced against
// this hook: a flag staged outside armed.d and left alone, then symlinked into armed.d
// two seconds AFTER a legitimate arm, still sorted first and restored the attacker's
// checkpoint. The link's OWN lstat ctime was correct; nothing was reading it. A
// hardlink is not the same problem — link() is a metadata write and moves the inode's
// ctime forward, measured alongside.
//
// Refusing outright rather than ordering by the link's own ctime: `arm.sh` writes
// through mktemp + rename and has never produced anything but a regular file, the
// legacy writer likewise, and this file already refuses a symlinked `context-cycle/`
// or `armed.d/` on the same reasoning one level up (see realDir). Nothing legitimate
// makes an arm flag a link.
//
// What this lstat is NOT is the thing that makes the read safe — openArm's O_NOFOLLOW
// is. Classifying by path here and reading by path later left a window an attacker
// could swap the entry through. This stays because it is what makes a non-flag entry
// REPORTABLE, and what keeps the sweep from ever considering one.
//
// A refused entry is left on disk, never unlinked. unlinkSync on a symlink would only
// remove the link, so deleting would be safe — but this hook does not delete what it
// declines to read, and a well-formed planted FILE was never swept either. The skip is
// reported (see the banner) rather than silent, because a silent non-restore on a
// setup that works is the failure this project keeps finding, and someone whose
// dotfile manager symlinks individual files would otherwise get nothing and no reason.
function realFile(p) {
  try { return lstatSync(p).isFile(); } catch { return false; }
}
function scanArms() {
  const arms = [], odd = [];
  if (!stateDirUsable()) return { arms, odd };
  const consider = (p) => {
    let st;
    try { st = lstatSync(p); } catch { return; }   // absent: not a flag, not an anomaly
    (st.isFile() ? arms : odd).push(p);
  };
  consider(legacyArmedPath);
  if (!armDirUsable()) return { arms, odd };
  try {
    for (const name of readdirSync(armDir)) {
      if (name.endsWith('.json') && !name.startsWith('.tmp.')) consider(join(armDir, name));
    }
  } catch { /* armed.d may not exist yet */ }
  return { arms, odd };
}
function armPaths() { return scanArms().arms; }

// Everything a caller needs to know about one arm flag, answered off a SINGLE open
// file description: is it a regular file, when was its inode last changed (the sort
// key), when was its content last written (the litter clock), and what does it say.
//
// It is one call because the alternative was a TOCTOU. scanArms() classifies by path
// with lstat; a separate readFileSync(path) and statSync(path) afterwards each resolve
// the NAME again, and both follow symlinks. A same-uid attacker who can write armed.d
// — the threat model this whole area is written against — can leave a regular file
// there long enough to be classified, then unlink-and-symlink it at a pre-staged file
// with an old ctime and content of their choosing. One miss costs nothing and armed.d
// is rescanned on every /clear, so the window is narrow but the retry budget is not.
// That reopens exactly the forgery the lstat refusal was added to close.
//
// O_NOFOLLOW makes the open itself the check: it fails with ELOOP on a symlink, so
// there is no window between deciding and reading. fstat then reports the inode
// actually open, not whatever the name resolves to a moment later, and the content
// comes from the same descriptor. scanArms()'s lstat stays — it is what makes a
// non-flag entry REPORTABLE (see linkNote), and it keeps the sweep from ever
// considering one — but it is no longer what makes the read safe.
//
// Scope, since O_NOFOLLOW is POSIX: Node exposes it as undefined on Windows, where
// this degrades to `| 0` and the open follows a reparse point as it always did. That
// is the same platform where ctime is not the guarantee the ORDERING note describes, and for
// the same reason — stated here rather than left for someone to infer.
//
// Return shapes, deliberately three rather than a null and a guess:
//   null                     — nothing usable at that path: gone (a concurrent hook
//                              consumed it, which is ordinary), unreadable, or not a
//                              regular file. Not an anomaly; not reported.
//   { linked: true }         — it WAS a regular file when scanArms() looked and is a
//                              symlink now. That is the swap above, and it is worth
//                              saying out loud, so it joins the same banner as an
//                              entry that was a link all along.
//   { arm, order, mtimeMs }  — opened. `arm` is null when the JSON did not parse,
//                              which sweep() treats as litter rather than as a flag.
const O_NOFOLLOW = constants.O_NOFOLLOW || 0;
function openArm(p) {
  let fd;
  try {
    fd = openSync(p, constants.O_RDONLY | O_NOFOLLOW);
  } catch (e) {
    return e && e.code === 'ELOOP' ? { linked: true } : null;
  }
  try {
    const st = fstatSync(fd);
    if (!st.isFile()) return null;
    let arm = null;
    try {
      const o = JSON.parse(readFileSync(fd, 'utf8'));
      if (o && typeof o === 'object') arm = o;
    } catch { /* unreadable, malformed, or mid-write */ }
    // Unreadable ctime => Infinity, so it sorts LAST. See the ORDERING note: falling
    // back to a field the flag supplied would hand the hole straight back.
    const order = Number.isFinite(st.ctimeMs) && st.ctimeMs > 0 ? st.ctimeMs : Infinity;
    return { arm, order, mtimeMs: st.mtimeMs };
  } catch {
    return null;
  } finally {
    try { closeSync(fd); } catch { /* ignore */ }
  }
}

// Live = parses, carries a usable armed_at, and — only when the user opted into a
// bound via CONTEXT_CYCLE_TTL — sits inside it. With no bound, age is not consulted
// at all and only the shape is checked.
//
// armed_at stays REQUIRED even though nothing expires and it no longer orders
// anything: every flag this tool has ever written carries it, so its absence marks a
// flag this tool did not write, and the age disclosure at the bottom reads it. A
// far-future stamp is no longer junk on its own — with no upper bound there is nothing
// for it to be junk relative to, and clock skew across a suspend/resume or a restored
// VM snapshot is an honest way to get one.
//
// It must also be POSITIVE, which is now purely a shape check: `date +%s` cannot
// produce it, so a flag that carries it was hand-written. It used to be load-bearing
// against a planted flag stamped 0 winning the ascending sort outright; ordering has
// since moved off this field entirely (see ORDERING below), which closed that properly —
// a forgery only had to say `1` to get past a check on the sign.
//
// Accepted cost, because this is not quite "no honest flag can look like that": a
// machine whose clock is still at the epoch when the arm is written — dead RTC, no
// NTP yet, ordinary enough on a headless box — produces a genuine flag that this
// rejects, and sweep() then deletes it rather than merely skipping it. The checkpoint
// file survives, the pending restore does not. It is the same fate every other
// malformed armed_at has always had, and it errs toward losing a restore rather than
// firing a planted one, which is the correct direction for a hook that injects into
// model context.
//
// What is left of the flag's trust problem after this and the ctime ordering is the flag
// itself: nothing here authenticates who wrote one (TODOS.md, "an arm flag on disk is
// trusted wholesale").
function isLive(arm, now) {
  if (!arm || typeof arm.armed_at !== 'number' || !Number.isFinite(arm.armed_at)) return false;
  if (arm.armed_at <= 0) return false;
  if (!ARM_TTL_SECONDS) return true;
  const age = now - arm.armed_at;
  return age <= ARM_TTL_SECONDS && age > -ARM_TTL_SECONDS;
}

// ORDERING. Why `order` above is the inode's change time — the only piece of arm
// metadata that does NOT come out of the flag's own JSON. Kept as prose next to
// isLive() rather than folded into openArm(), which is now where it is computed,
// because it is the argument for the whole design and not a note about one expression.
//
// The sort used to run on `armed_at`. That field is written by whoever wrote the
// flag, so a planted one carrying a small timestamp sorted ahead of every legitimate
// arm in its project and won every /clear, deterministically, instead of having to
// win a race. Requiring `armed_at > 0` removed only the laziest spelling of that:
// `1` works exactly as well as `0`.
//
// The inode's change time is not writable. There is no syscall that sets it — it is
// updated as a side effect of every metadata write, so backdating mtime moves ctime
// FORWARD, and so does the rename arm.sh writes through. Measured on this repo's
// Linux target rather than read off a manual page: `touch -d 2020-01-01` and
// `utimesSync(0)` each leave mtime in the past and ctime at the current time.
//
// So arms are ordered by when they were actually written, which is what the sort was
// always trying to express — `armed_at` was standing in for it. A flag can no longer
// claim to predate an arm that was written before it.
//
// Two things this does NOT do, both pinned by assertions in group 23 rather than left
// to prose. It does not authenticate the writer: a flag planted BEFORE a legitimate
// arm genuinely is older and still sorts first. And it is not a defence on its own —
// losing the sort costs an attacker one cycle, since the flag stays on disk and is a
// candidate again at the next /clear. Ordering is the half of the arm-flag trust
// problem that a check can reach; the other half is in TODOS.md and no check here
// closes it.
//
// Unreadable => Infinity, so it sorts LAST. Falling back to `armed_at` would hand the
// hole back to anyone who could make the stat fail, and sorting last costs a
// legitimate arm nothing permanent for the reason just given. Ties (both Infinity, or
// the same millisecond) fall through to the path comparison at the call site, which
// is deterministic and reads nothing from the flag either.
//
// This is only sound because it reads ctime off an O_NOFOLLOW descriptor rather than
// off a path (openArm). A path-based statSync FOLLOWS a symlink, so on a linked entry
// it reports the TARGET's ctime and the whole guarantee evaporates — an attacker
// stages a file, never touches it again, and links it in whenever they like.
// Reproduced twice against earlier versions of this file: once when there was no
// refusal at all, and once when the refusal was an lstat in scanArms() that a swap
// between the classify and the read could step around. Ordering and the descriptor
// belong together; neither is sufficient alone.
//
// Scope, stated because it is narrower than the code looks. "Cannot be forged" means
// "not by any call that operates on the file"; it is not absolute. Whoever serves the
// filesystem under armed.d/ (a FUSE mount) or sets the system clock can state any
// ctime they like — both strictly stronger primitives than writing an arm flag, and so
// inside the same threat-model bound as the rest of this file. And it is a POSIX
// property: Windows has no ctime in that sense — libuv reports NTFS's ChangeTime,
// which the native API CAN set, and O_NOFOLLOW does not exist there either — so on
// that platform this orders by write time without guaranteeing it. Untested there.

function drop(p) { try { unlinkSync(p); } catch { /* ignore */ } }

// Collect litter on every session start, so armed.d cannot grow without bound on a
// machine where cycles get armed and abandoned. Never touches checkpoints.
//
// Since arms no longer age out, an intact flag is dropped here only when it is
// malformed (no usable armed_at) or when the user set CONTEXT_CYCLE_TTL and it fell
// outside. An abandoned but well-formed arm is left alone on purpose: it is waiting
// for a /clear in its own project, and there is no deadline on that.
function sweep(now) {
  for (const p of armPaths()) {
    const a = openArm(p);
    // Not a flag right now — gone, unreadable, or swapped for a link since the scan.
    // Reaping is a delete, so it declines on anything it could not positively identify.
    if (!a || a.linked) continue;
    if (a.arm === null) {
      // Unparseable. Could be a concurrent arm.sh mid-write, so only reap it once
      // it is past the litter horizon — a live arm must never be destroyed. mtime
      // comes off the same descriptor the content did, so a swap cannot make this
      // stat a different inode than the one that failed to parse.
      if (now - a.mtimeMs / 1000 > LITTER_TTL_SECONDS) drop(p);
      continue;
    }
    if (!isLive(a.arm, now)) drop(p);
  }
  if (!armDirUsable()) return;
  try {
    for (const name of readdirSync(armDir)) {
      if (!name.startsWith('.tmp.')) continue;
      const p = join(armDir, name);
      try { if (now - statSync(p).mtimeMs / 1000 > LITTER_TTL_SECONDS) drop(p); } catch { /* ignore */ }
    }
  } catch { /* armed.d may not exist yet */ }
}

// Project scope: only restore in the project the flag was armed in.
//   - exact match wins outright;
//   - a cwd BELOW the armed root still matches (the session may have been started
//     in a subdirectory, or the arming Bash call may have cd'd elsewhere in the
//     repo) — but not when that subdirectory is itself a repo boundary, which is
//     how a nested repo or submodule in a monorepo gets correctly rejected;
//   - an arm with no recorded cwd (hand-written / very old) is unscoped;
//   - an unknown current cwd fails closed and leaves the arm alone.
// Resolve to a canonical path before comparing. The two sides come from different
// places and legitimately name the same directory in different forms: arm.cwd is
// `git rev-parse --show-toplevel`, which returns the PHYSICAL path, while the
// payload cwd is whatever the session was launched in, which may be logical. On
// macOS a repo under /tmp or /var is /private/... to git and /... to the shell; in
// Git Bash the same directory can be an 8.3 short name on one side and the long
// name on the other. Neither is reconcilable by string rewriting, and a mismatch
// fails silently — the arm simply never matches and the restore does nothing.
// Falls back to the raw string when the path cannot be resolved (deleted, or a
// hand-written flag), which preserves the old behaviour for those cases.
// `.native` first, and the order is load-bearing on Windows. It calls
// GetFinalPathNameByHandle, which expands an 8.3 short name to the long one; the JS
// `realpathSync` resolves symlinks but leaves a short name short. That is the whole
// Windows failure: arm.sh records `git rev-parse --show-toplevel`, which Git for
// Windows reports as the LONG name, while the cwd handed to the hook can still be
// the short form. Measured on a Git Bash CI runner, same directory:
//   show-toplevel        C:/Users/runneradmin/AppData/Local/Temp/tmp.X
//   payload cwd          C:/Users/RUNNER~1/AppData/Local/Temp/tmp.X
//   realpathSync         C:\Users\RUNNER~1\...        <- still short, never matched
//   realpathSync.native  C:\Users\runneradmin\...     <- matches
// Falls back to the JS implementation and then to the raw string: `.native` can
// throw where the JS one succeeds, and both throw on a path that no longer exists —
// a deleted or hand-written flag, which keeps its previous behaviour either way.
function canon(p) {
  if (!p) return '';
  const s = String(p);
  try { return realpathSync.native(s); } catch { /* fall through */ }
  try { return realpathSync(s); } catch { return s; }
}

// Canonicalizing is what makes the two path forms match, but on its own it is also a
// widening: ANY symlink on the clearing cwd now aliases into whatever it targets. A
// link planted inside repo B and pointed at project A pulls A's checkpoint into a
// session nominally working in B. Reproduced against the un-narrowed version.
//
// At the leaf the two cases are indistinguishable — in both, the cwd resolves to a
// project directory it is not literally named after — so no test on the cwd itself
// separates them. What separates them is what the raw path walked THROUGH. A macOS
// /var alias, a Git Bash short name, and a plain symlink to a project directory all
// have no repository above them; a link inside project B does, and that repo is not
// the one we landed in. So: when resolution actually moved the path, the resolved cwd
// must still be INSIDE the repository the raw path belongs to as written.
//
// "Inside", not "equal to" — the difference is the whole of a bug this used to have,
// and the reasoning lives at the call site in scopeAllows().
//
// Only walks when the raw and canonical forms differ, so the common case pays nothing.
//
// The trigger is any string divergence, not specifically a symlink hop, so a literal
// '..' segment resolving back to the same directory also walks. Left as-is: the
// payload cwd is Claude Code's own resolved path and does not carry '..', and if it
// ever did, the outcome is the same conservative non-restore rather than a widening.
// Walks to the filesystem root with NO iteration cap, deliberately. A cap here is
// not a safety valve, it is a bypass: "ran out of budget" returns the same empty
// string as "there is genuinely no repo above", and the caller reads that as "benign
// alias, allow" — so burying the planted link under enough directories walks the
// guard straight out of budget and reopens the hole. Reproduced at depth 70 against
// a 64-iteration version; blocked at 63. Unbounded is safe: `p` loses at least one
// character per pass and the loop stops at the first component, so it terminates in
// at most one iteration per separator in the path.
//
// The backslash collapse is gated on win32 for the same reason norm()'s is, and here
// it is not a theoretical tidy-up: on POSIX a backslash is an ordinary filename
// character, so collapsing it splits one directory name into two, the walk then stats
// `.git` under paths that do not exist, finds nothing, and returns '' — which the
// caller reads as "no repo above, benign alias, allow". Reproduced: a repo literally
// named `evil\repo` holding a symlink to the armed project restored through it while
// the same shape named `evilrepo` was blocked.
function rawEnclosingRepo(rawPath) {
  let p = String(rawPath);
  if (IS_WIN) p = p.replace(/\\/g, '/');
  p = p.replace(/\/+$/, '');
  for (;;) {
    const cut = p.lastIndexOf('/');
    if (cut <= 0) return '';
    p = p.slice(0, cut);
    try { if (existsSync(join(p, '.git'))) return p; } catch { /* unreadable: keep walking */ }
  }
}

// Best-effort current branch, for the drift disclosure at the bottom. Called only on
// the restore path, never on an ordinary session start.
//
// Reads .git/HEAD directly instead of shelling out. The hook has no dependency on a
// `git` binary today and this is not worth adding one for: git missing from PATH, or
// slow on a cold network mount, would then degrade a restore that has already passed
// every gate. Nothing here justifies that.
//
// Returns '' for everything it does not positively understand — a detached HEAD, a
// bare `.git` FILE (worktrees and submodules, whose real gitdir is elsewhere), an
// unreadable repo, no repo at all. '' means "say nothing about drift", which is the
// safe direction: a wrong branch name in the header would be worse than no line.
function currentBranch(cwdRaw) {
  let p = String(cwdRaw || '');
  if (!p) return '';
  if (IS_WIN) p = p.replace(/\\/g, '/');
  p = p.replace(/\/+$/, '');
  for (;;) {
    try {
      const g = join(p, '.git');
      if (existsSync(g)) {
        // A bare `.git` FILE is a worktree or submodule whose real gitdir is elsewhere.
        // Stop here rather than continue the walk: the next `.git` DIRECTORY up the tree
        // belongs to the superproject or the main worktree, and reporting its branch as
        // "the branch this session is on" is a wrong answer, not a missing one — it
        // fabricates drift, or hides real drift, in the one place the user is being
        // asked to trust the disclosure.
        if (!statSync(g).isDirectory()) return '';
        const m = /^ref:\s*refs\/heads\/(.+)$/.exec(readFileSync(join(g, 'HEAD'), 'utf8').trim());
        return m ? m[1] : '';
      }
    } catch { return ''; }
    const cut = p.lastIndexOf('/');
    if (cut <= 0) return '';
    p = p.slice(0, cut);
  }
}

// Coarse on purpose: the reader needs "is this from today or from last week", not a
// duration. Negative ages (clock skew, restored snapshot) return '' rather than a
// nonsense "-3h" — isLive() no longer rejects a future stamp, so this has to cope.
function humanAge(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return '';
  const mins = Math.floor(seconds / 60);
  if (mins < 60) return `${mins}m`;
  const hours = Math.floor(mins / 60);
  if (hours < 48) return `${hours}h`;
  return `${Math.floor(hours / 24)}d`;
}

// An arm whose `cwd` is missing, empty or unusable is REFUSED, not treated as
// project-wide. It used to match the next /clear in ANY project, which turned a
// hand-written flag into a prompt-injection primitive: attacker-chosen file content
// injected as additionalContext under this hook's own "resume from this" framing.
//
// Refusing costs nothing real, because no arm.sh has ever written a flag without
// this field. Every version back to v1.0.0's single-slot armed.json writes
// `git rev-parse --show-toplevel 2>/dev/null || pwd`, which cannot produce an empty
// string — so absence is not a shape this tool emits, it is a shape someone else
// wrote.
//
// DELIBERATELY no exemption for the legacy armed.json. The review that found this
// suggested one, to keep a pre-upgrade cycle from stranding; the legacy writer
// emitted `cwd` from that same line, so the exemption would rescue nothing that
// exists and would hand the primitive straight back — armed.json sits in the very
// directory an attacker needs to write to plant an armed.d flag in the first place.
//
// Fallout accepted: "/" normalises to '' here, so a cycle armed with the filesystem
// root as its project is refused too. `git rev-parse --show-toplevel` cannot return
// it from a real repo, and "every project on the machine" is precisely the reading
// this function must stop.
function scopeAllows(armedCwd, curCwdRaw) {
  if (!norm(armedCwd)) return false;
  const a = norm(canon(armedCwd));
  const cRaw = canon(curCwdRaw);
  const c = norm(cRaw);
  if (!c) return false;
  // The aliasing guard (see rawEnclosingRepo above). It asks whether resolution carried
  // the cwd OUT of the repository the raw path belongs to as written — NOT whether that
  // repository *is* the armed project, which is what it asked before and which refused
  // every project legitimately nested inside another one. A worktree or a submodule has
  // the outer repo above it as written, so `/tmp/link/proj/wt` was refused while
  // `/tmp/real/proj/wt` restored: same fixture, same shell, same OS. A property of the
  // path, not the platform, which is why macOS and Windows CI hit it and Linux did not.
  // The armed and clearing cwd being the identical string did not save it — the old
  // form never compared them.
  //
  // Residual, measured rather than inferred, and not closable from here: this can only
  // be as strong as the nearest repo above the raw path. Where that repo canonicalizes
  // to an ancestor of the armed project, any link SITTING under it resolves to somewhere
  // inside it and passes — where the link lives is what counts, not where it points.
  // The precondition is weaker than "you use yadm", too: rawEnclosingRepo() stops at any
  // entry named `.git`, file or directory, real repository or not.
  // The benign shape is the same mechanism (a user's own shortcut under a repo-shaped
  // $HOME, which this now restores instead of silently refusing), so nothing here can
  // separate them. Bounded like the rest of TODOS.md's threat model: the injected
  // content is the user's own checkpoint, and the cwd physically IS the armed project.
  //
  // Refusing when the enclosing repo is ITSELF a symlink does block that residual — it
  // was tried and measured — but it also silently breaks `ln -s /mnt/big/proj ~/proj`
  // plus a /clear from any subdirectory, which works today. A silent non-restore on a
  // working setup is the worse of the two, so it was rejected.
  // The second condition keeps the first from widening a DIFFERENT, already-open gap:
  // a /clear in a subdirectory of a repo nested BELOW the armed project matches the
  // parent's arm, because the check further down stats `.git` in the leaf only (still
  // open, still in TODOS.md — closing it costs a stat per ancestor on every session
  // start). Containment alone made that gap reachable through a symlink as well, where
  // the old form refused: armed at `main`, a separate repo at `main/vendor/subrepo`,
  // and `/clear` in `slink/src` where `slink` -> that subrepo. Reproduced both ways.
  // Refusing when the raw path's repo sits strictly inside the armed project restores
  // the old boundary exactly. It does NOT close the gap on the direct path, so the two
  // routes now disagree — `main/vendor/subrepo/src` still matches, `slink/src` does
  // not. That asymmetry is the pre-change behaviour, kept deliberately: this change is
  // meant to be scope-neutral for that item, not to quietly take half of it.
  if (norm(curCwdRaw) !== c) {
    const rawRepo = rawEnclosingRepo(curCwdRaw);
    if (rawRepo) {
      const r = norm(canon(rawRepo));
      if (r && r.startsWith(a + '/')) return false;
      if (r && c !== r && !c.startsWith(r + '/')) return false;
    }
  }
  if (a === c) return true;
  if (!c.startsWith(a + '/')) return false;
  try { return !existsSync(join(cRaw, '.git')); } catch { return true; }
}

// MSYS /c/... -> C:/... for native Windows node.
function winPath(cp) {
  if (process.platform !== 'win32' || typeof cp !== 'string') return cp;
  const m = /^\/([a-zA-Z])\/(.*)$/.exec(cp);
  return m ? m[1].toUpperCase() + ':/' + m[2] : cp;
}

// --- Where a checkpoint is allowed to live ----------------------------------
//
// `checkpoint` used to be read verbatim from any absolute path the flag named. That
// made an arm flag an arbitrary-file-READ primitive: whoever could write
// armed.d/*.json could have any file the user can read injected into model context
// under this hook's own "resume from this" framing. ~/.ssh/id_rsa, a .env, a private
// repo's notes — none of them look like a checkpoint, and nothing checked.
//
// What this closes, precisely: the read is now confined to directories checkpoints
// are actually written to. What it does NOT close, and this is the larger half — an
// attacker who can write the arm flag can usually also write INTO those directories,
// and a file they put there is read exactly as before. So this removes the
// arbitrary-read, not the injection. The injection needs the provenance check
// TODOS.md tracks, and no path test can substitute for it.
//
// Two roots, because /context-cycle writes to two places (SKILL.md step 1):
//   $CLAUDE_CONFIG_DIR/context-cycle/checkpoints/$SLUG   (standalone)
//   $GSTACK_STATE_ROOT/projects/$SLUG/checkpoints        (gstack installed)
// Confining to the first alone would silently break every gstack user, and this
// project has already decided once that a silent non-restore on a working setup is
// the worst available outcome.
//
// The second root is derived, never executed. gstack ships bin/gstack-paths, and
// SKILL.md gets the value by eval'ing it — fine for a skill's bash block, not for a
// hook: shelling out to another tool on every session start is the thing the
// `currentBranch()` note above refuses to do, and it would put a third party's
// executable on the restore path. gstack's own chain for GSTACK_STATE_ROOT is pure
// env-var logic with no filesystem lookup, so it can simply be read off and
// reimplemented (read from bin/gstack-paths, gstack as installed 2026-08-07):
//   GSTACK_HOME -> CLAUDE_PLUGIN_DATA (only when CLAUDE_PLUGIN_ROOT matches gstack)
//                                     -> $HOME/.gstack -> .gstack
// The last fallback is deliberately dropped. It is relative, and a hook's cwd is
// whatever directory the session started in — anchoring a trust root there would
// make the allowed set depend on where you happened to be standing.
//
// Copying a third party's logic is a coupling, and it is the one real fragility
// here: if gstack changes that chain, this stops recognizing a legitimate
// checkpoint. That is why the refusal is loud, keeps the arm, and names an env var
// (below) — a wrong root costs a message and a re-clear, not a lost checkpoint.
function gstackStateRoot() {
  const home = (process.env.GSTACK_HOME || '').trim();
  if (home) return home;
  const data = (process.env.CLAUDE_PLUGIN_DATA || '').trim();
  if (data && /gstack/i.test(process.env.CLAUDE_PLUGIN_ROOT || '')) return data;
  const h = homedir();
  return h ? join(h, '.gstack') : '';
}

// CONTEXT_CYCLE_CHECKPOINT_ROOTS: PATH-separated extra roots, for anyone whose
// checkpoints legitimately live somewhere neither branch above can derive. It is an
// escape hatch, not a weakening: an attacker who can set env vars for the Claude Code
// process already has a strictly stronger primitive than writing an arm flag, which
// is the same bound the rest of this file's threat model runs on.
//
// Roots are canonicalized, and so is the candidate, so a symlinked ~/.claude
// (stow/chezmoi — group 16) and a symlinked checkpoints directory both still match,
// while a symlink INSIDE a root that points out of it does not.
function checkpointRoots() {
  const raw = [join(claudeDir, 'context-cycle', 'checkpoints')];
  const g = gstackStateRoot();
  if (g) raw.push(join(g, 'projects'));
  for (const extra of String(process.env.CONTEXT_CYCLE_CHECKPOINT_ROOTS || '').split(delimiter)) {
    const t = extra.trim();
    if (t) raw.push(t);
  }
  const out = [];
  for (const r of raw) {
    const n = norm(canon(r));
    if (n && !out.includes(n)) out.push(n);
  }
  return out;
}
const CHECKPOINT_ROOTS = checkpointRoots();

// Relative paths are refused rather than resolved: the base would be the session's
// cwd, which is not a trust anchor. `..` is handled by canon() collapsing it — and
// where the path does not exist canon() falls back to the raw string, so normalize()
// runs too, otherwise `<root>/../../etc/passwd` would pass a prefix test on its own
// spelling. Membership is `=== root` or `startsWith(root + '/')`, never a bare
// startsWith: `<root>-evil/x` is not inside `<root>`.
//
// Returns the RESOLVED path to read, not a boolean, and the caller reads from that
// rather than from the string it passed in. Re-resolving the original at read time
// would leave a symlink-swap window: a link inside a root pointing at another
// in-root file passes here, and pointing it at ~/.ssh/id_rsa before the read gives
// back exactly the arbitrary read this function exists to stop. Reading the resolved
// path shrinks the residue to replacing the file that path already names — which is
// writing your own content into a root, no race and nothing new. `norm()` is for
// comparison only (it lowercases on Windows); the returned value is pre-norm.
function allowedCheckpoint(cp) {
  if (typeof cp !== 'string' || !cp) return '';
  if (!isAbsolute(cp)) return '';
  const real = canon(normalize(cp));
  const c = norm(real);
  if (!c) return '';
  return CHECKPOINT_ROOTS.some((r) => c === r || c.startsWith(r + '/')) ? real : '';
}

// A refused path is shown back to the user so a wrong root is diagnosable, and it is
// attacker-influenceable, so strip the control bytes that would let it move the
// cursor or emit escape sequences in the terminal, plus the zero-width and bidi
// overrides that would let it render as a path it is not. Display only — the
// comparison above runs on the real string, and this never reaches model context,
// which is why this strips a named set rather than using safeRef()'s allowlist: a
// path the user has to recognise has to survive non-ASCII, and the markdown/prompt
// injection safeRef() defends against needs a channel the model reads.
function safePath(p) {
  const strip = /[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069]/g;
  return clamp(String(p).replace(strip, '?'), 160);
}

// Read the hook payload (source + cwd).
let payload = {};
try {
  const raw = readFileSync(0, 'utf8');
  if (raw && raw.trim()) payload = JSON.parse(raw);
} catch { /* ignore */ }

const now = Math.floor(Date.now() / 1000);
try { sweep(now); } catch { /* a sweep failure must never break session start */ }

if (payload.source !== 'clear') noop();   // non-clear, or no evidence of one

// Candidate arms: live, and armed in this project. `odd` is every armed.d entry
// scanArms() would not treat as a flag at all — never read, never ordered, only
// reported (see warnings()). Both accumulators are declared here so the early exits
// below can report through the same channel as the successful path.
const { arms: armFiles, odd: oddArms } = scanArms();
const refused = [];
const candidates = [];
for (const p of armFiles) {
  const a = openArm(p);
  // Classified as a regular file a moment ago, a symlink by the time it was opened.
  // Nothing legitimate does that, so it goes in the same banner as one that was a
  // link when scanArms() looked. `!a` alone does not: a flag that simply vanished is
  // an ordinary race between two sessions clearing at once, not an anomaly.
  if (a && a.linked) { oddArms.push(p); continue; }
  if (!a || !isLive(a.arm, now)) continue;
  if (!scopeAllows(a.arm.cwd, payload.cwd)) continue;      // wrong project -> leave armed
  candidates.push({ path: p, arm: a.arm, order: a.order });
}
if (!candidates.length) { warn(); noop(); }

// Oldest first, by the inode's change time rather than the flag's own `armed_at` —
// see the ORDERING note above. When two sessions in one project clear in the order they armed,
// each gets its own checkpoint back. (Out-of-order clears can still mis-pair —
// nothing in the payload says which session is clearing. See SKILL.md.)
//
// Compared with an explicit three-way rather than a subtraction: `Infinity - Infinity`
// is NaN, and while NaN happens to be falsy and therefore happens to fall through to
// the tiebreak, a comparator whose correctness rests on that is one edit away from
// being wrong. Neither term reads a field the flag supplied.
candidates.sort((x, y) =>
  (x.order === y.order ? 0 : x.order < y.order ? -1 : 1) || x.path.localeCompare(y.path));

let chosen = null;
for (const c of candidates) {
  const cp = winPath(c.arm.checkpoint);
  let body = '';
  let here = false;
  try { here = !!cp && existsSync(cp); } catch { /* ignore */ }
  // Order matters. Root membership is only consulted for a checkpoint that is
  // actually THERE: a flag naming a path that no longer exists is dead whatever the
  // policy says, and letting it fall through to drop() keeps the disposal of dead
  // flags exactly as it was rather than turning every stale one into a permanent
  // resident that the sweep will not reap either.
  const real = here ? allowedCheckpoint(cp) : '';
  if (here && !real) {
    // Refused, and deliberately NOT dropped. The likeliest cause of a wrong refusal
    // is a checkpoint root this hook could not derive, and dropping would destroy a
    // legitimate pending restore to punish a configuration mistake. Left armed, the
    // fix is one env var and one more /clear; the checkpoint file is untouched
    // either way. For a planted flag, leaving it costs nothing — it never fires, and
    // an attacker who can write one can write another.
    refused.push(cp);
    continue;
  }
  try { if (real) body = readFileSync(real, 'utf8'); } catch { /* ignore */ }
  if (body.trim()) { chosen = { path: c.path, arm: c.arm, cp, body, order: c.order }; break; }
  drop(c.path);            // checkpoint gone: the flag is dead. The file is not.
}

// Refusing has to be LOUD. Every other way this hook declines to fire is a
// non-event by design — wrong project, no arm, nothing pending — but this one means
// a checkpoint the user asked for exists on disk and is being withheld, and /clear
// has already taken their context window. Silence there is the exact failure this
// project keeps finding: the clear looked normal and nothing came back.
function refusalNote() {
  const n = refused.length;
  return `${n} arm${n === 1 ? '' : 's'} not restored: checkpoint outside the known ` +
    `checkpoint directories (${safePath(refused[0])}${n > 1 ? ', …' : ''}). ` +
    `Set CONTEXT_CYCLE_CHECKPOINT_ROOTS if that location is legitimate; the arm was kept.`;
}

// The same argument, one level earlier: scanArms() declined to even open these, so
// nothing downstream can report them. Left silent, the whole symlink refusal would be
// invisible in both directions — an attacker learns nothing either way, and a user
// whose setup genuinely produced a link gets no restore and no reason, which is the
// failure mode this project keeps rediscovering. Says what it is rather than accusing:
// the honest reading is "something put a link here", not "you are under attack".
//
// Noise is bounded but real. armed.d is global, so a stray entry is reported on every
// /clear in every project until it is removed — deliberately, since the hook cannot
// read the entry to find out whose project it belongs to, and cannot delete it either
// (see scanArms). The note names the path and the fix.
function linkNote() {
  const n = oddArms.length;
  return `${n} armed.d entr${n === 1 ? 'y was' : 'ies were'} ignored: not a regular ` +
    `file (${safePath(oddArms[0])}${n > 1 ? ', …' : ''}). /context-cycle writes arm ` +
    `flags as plain files, so a symlink or directory there was written by something ` +
    `else and is not read. Remove it; re-run /context-cycle if you expected a restore.`;
}

function warnings() {
  const w = [];
  if (oddArms.length) w.push(linkNote());
  if (refused.length) w.push(refusalNote());
  return w;
}
// Emit the warnings on a path that injects nothing. Safe before noop(): writeSync is
// synchronous, and a systemMessage with no hookSpecificOutput restores nothing.
function warn() {
  const w = warnings();
  if (w.length) writeSync(1, JSON.stringify({ systemMessage: w.map((s) => '⚠ ' + s).join('\n') }));
}
if (!chosen) { warn(); noop(); }

// Passed every gate: this is the restore. Consume this one arm, then inject.
drop(chosen.path);

let body = chosen.body;
const cp = chosen.cp;

// Parse the title + first remaining-work item from the FULL body (before any
// truncation below) for the clear-time banner.
const { title, nextStep } = parseCheckpoint(body);

// additionalContext is capped (~10k chars). Leave headroom; if the checkpoint is
// bigger, inject a head slice and point at the full file on disk.
const MAX = 9000;
let note = '';
if (body.length > MAX) {
  body = body.slice(0, MAX);
  note = `\n\n[...truncated. Full checkpoint on disk: ${cp}]`;
}

// Clear-time confirmation banner (systemMessage). Enriched with WHAT was restored —
// the title and the next step — so it's not just a bare "restored" receipt, and so
// a mis-paired restore (two sessions, same project, out-of-order clears) is visible
// to the user instead of silent. Falls back to the plain form when the checkpoint
// couldn't be parsed.
let confirmLine = '✓ Restored';
confirmLine += title ? `: "${clamp(title, 60)}"` : ' context via /context-cycle';
if (nextStep) confirmLine += ` · next: ${clamp(nextStep, 80)}`;
const armedBranchRaw = chosen.arm.branch ? clamp(String(chosen.arm.branch), 60) : '';
const armedBranch = safeRef(armedBranchRaw);
if (armedBranch) confirmLine += title ? ` (${armedBranch})` : ` (branch: ${armedBranch})`;

// Staleness disclosure. Arms do not expire, so a checkpoint can now be arbitrarily
// old — that is the point, and the AFK case is exactly what it is for. The one way
// it bites is silently resuming a plan the world has moved past: the checkpoint says
// "PR open, waiting on review", the PR merged two days ago, and the header's own
// "resume from this, do not repeat work already marked done" framing makes the model
// trust it. So say the two things that make an old restore checkable — how old, and
// whether the branch moved — and say them in BOTH channels, since the banner is the
// only one the user sees and the header is the only one the model sees.
//
// Silent when there is nothing to report: a cycle-and-clear inside the same sitting,
// which is the common case, reads exactly as it did before. STALE_AFTER is a
// readability threshold, not a safety one — nothing changes behaviour at 4h.
const STALE_AFTER = 4 * 3600;

// Age is the OLDER of what the flag says about itself and when the flag was actually
// written. Two independent reasons, and they point the same way:
//
// - `armed_at` is written by whoever wrote the flag, so on its own it can under-report
//   — a flag stamped `now` reads as fresh however long it has sat there, and this
//   disclosure is the only thing telling the model to re-check a stale plan. Since
//   ordering moved to the inode's change time (see ORDERING), the two were decoupled:
//   the hook was sorting on one clock and reporting on another. This re-couples them.
// - It also fixes an honest case with no attacker in it. A flag whose `armed_at` is
//   wrong because the machine's clock was wrong when it was written — suspend/resume,
//   a restored VM snapshot, a box that boots before NTP — still gets its real age.
//
// Taking the max rather than replacing the field: over-reporting age is harmless (it
// asks for a re-check that was not strictly needed), under-reporting is the failure.
// Neither clock is trusted over the other; the more cautious one wins. `order` is
// Infinity when the stat failed, which is not an age — fall back to the flag's own.
//
// Only one direction of this is pinned by a test, and the gap is in TODOS.md: group 8
// covers an old `armed_at` on a freshly written flag (the max must not drop it). The
// converse — an old inode carrying a fresh `armed_at` — needs a flag genuinely older
// than STALE_AFTER, and ctime cannot be moved backwards, so the suite would have to
// wait four hours or move the system clock.
const armedAge = now - chosen.arm.armed_at;
const writtenAge = Number.isFinite(chosen.order) ? now - Math.floor(chosen.order / 1000) : armedAge;
const ageSeconds = Math.max(armedAge, writtenAge);
const ageLabel = humanAge(ageSeconds);
const isOld = ageSeconds >= STALE_AFTER && !!ageLabel;
const nowBranchRaw = clamp(currentBranch(payload.cwd), 60);
const nowBranch = safeRef(nowBranchRaw);
const drifted = !!armedBranchRaw && !!nowBranchRaw && armedBranchRaw !== nowBranchRaw;

if (isOld) confirmLine += ` · ${ageLabel} old`;
if (drifted) confirmLine += ` · now on ${nowBranch}`;

// A restore that succeeded on a later candidate still has to report the ones it
// walked past. Otherwise a planted flag that sorts first is refused invisibly — the
// user sees an ordinary green banner and never learns something on their disk is
// pointing the restore at a file it has no business reading. Same for an armed.d
// entry that was never a flag: a successful restore is exactly when it would go
// unnoticed.
for (const w of warnings()) confirmLine += `\n⚠ ${w}`;

const header =
  '## Restored working context (/context-cycle)\n' +
  'The previous conversation was saved and cleared via /context-cycle to free the ' +
  'context window. Below is the saved working state — resume from the "Remaining ' +
  'Work" section and do not repeat work already marked done.\n' +
  (armedBranch ? `Saved on branch: ${armedBranch}\n` : '') +
  (isOld ? `Saved ${ageLabel} ago.\n` : '') +
  (drifted
    ? `\n**The branch has changed since this was saved** — it was written on ` +
      `\`${armedBranch}\`, this session is on \`${nowBranch}\`. Treat the state below ` +
      `as a starting point, not as current: re-check the "Remaining Work" items ` +
      `against the repo before acting on them, because some may already be merged, ` +
      `abandoned, or done differently.\n`
    : '') +
  '\n**On your FIRST reply in this restored session, open with a 2–3 line recap** of ' +
  'what you picked up — the "Working on" title and the top 1–2 items from "Remaining ' +
  'Work" — then continue from there. Do NOT re-print the "✓ Restored" banner; the ' +
  'user already saw it at clear-time.\n' +
  '\n---\n\n';

// Two output channels, because /clear does NOT invoke the model:
//   - systemMessage (top-level): rendered to the USER at clear-time — the only
//     channel that shows anything the instant /clear runs.
//   - hookSpecificOutput.additionalContext: injected into the MODEL's context only
//     (invisible to the user); it carries the actual restored checkpoint.
const out = JSON.stringify({
  systemMessage: confirmLine,
  hookSpecificOutput: {
    hookEventName: 'SessionStart',
    additionalContext: header + body + note,
  },
});

// Synchronous write to fd 1: process.stdout.write + process.exit() can truncate a
// multi-KB payload on a pipe (the buffer is discarded before it drains), which
// silently drops the whole restore. writeSync guarantees the bytes land first.
writeSync(1, out);
noop();
