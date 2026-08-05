#!/usr/bin/env node
// SessionStart hook for the /context-cycle skill.
//
// Fires only when ALL of these hold:
//   (a) the payload says source === 'clear' (strict — see "fails closed" below),
//   (b) an "armed" flag written by /context-cycle exists and is fresh (< TTL),
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

import { readFileSync, readdirSync, statSync, lstatSync, realpathSync, existsSync, unlinkSync, writeSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const TTL_SECONDS = 3600; // a flag older than this is stale -> ignored + cleared

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

// Normalize a path for cross-tool comparison: backslashes -> '/', MSYS /c/ -> c:/,
// drop trailing slash, lowercase (Windows filesystem is case-insensitive).
function norm(p) {
  if (!p) return '';
  let s = String(p).replace(/\\/g, '/');
  const m = /^\/([a-zA-Z])\/(.*)$/.exec(s);
  if (m) s = m[1] + ':/' + m[2];
  return s.replace(/\/+$/, '').toLowerCase();
}

// Clamp to n chars with an ellipsis (for the one-line banner).
function clamp(s, n) {
  s = String(s);
  return s.length > n ? s.slice(0, n - 1).replace(/\s+$/, '') + '…' : s;
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
// single-slot armed.json if one is still lying around.
function armPaths() {
  const out = [];
  if (!stateDirUsable()) return out;
  if (existsSync(legacyArmedPath)) out.push(legacyArmedPath);
  if (!armDirUsable()) return out;
  try {
    for (const name of readdirSync(armDir)) {
      if (name.endsWith('.json') && !name.startsWith('.tmp.')) out.push(join(armDir, name));
    }
  } catch { /* armed.d may not exist yet */ }
  return out;
}

function readArm(p) {
  try {
    const o = JSON.parse(readFileSync(p, 'utf8'));
    if (o && typeof o === 'object') return o;
  } catch { /* unreadable, malformed, or mid-write */ }
  return null;
}

function isFresh(arm, now) {
  if (!arm || typeof arm.armed_at !== 'number') return false;
  const age = now - arm.armed_at;
  return age <= TTL_SECONDS && age > -TTL_SECONDS;         // future stamps = junk
}

function drop(p) { try { unlinkSync(p); } catch { /* ignore */ } }

// Reap expired arms on every session start, so armed.d cannot grow without bound
// on a machine where cycles get armed and abandoned. Never touches checkpoints.
function sweep(now) {
  for (const p of armPaths()) {
    const arm = readArm(p);
    if (arm === null) {
      // Unparseable. Could be a concurrent arm.sh mid-write, so only reap it once
      // it is older than the TTL — a live arm must never be destroyed.
      try { if (now - statSync(p).mtimeMs / 1000 > TTL_SECONDS) drop(p); } catch { /* ignore */ }
      continue;
    }
    if (!isFresh(arm, now)) drop(p);
  }
  if (!armDirUsable()) return;
  try {
    for (const name of readdirSync(armDir)) {
      if (!name.startsWith('.tmp.')) continue;
      const p = join(armDir, name);
      try { if (now - statSync(p).mtimeMs / 1000 > TTL_SECONDS) drop(p); } catch { /* ignore */ }
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
function canon(p) {
  if (!p) return '';
  const s = String(p);
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
// the one we landed in. So: when resolution actually moved the path, the repository
// the raw path belongs to *as written* must be the one the resolved path belongs to.
//
// Only walks when the raw and canonical forms differ, so the common case pays
// nothing. Known false negative, recorded in TODOS.md: a user whose $HOME is itself
// a git repo (yadm and friends) AND who reaches the project through a symlink under
// it trips this and silently gets no restore. Both conditions are needed; the
// conservative direction is not restoring.
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
function rawEnclosingRepo(rawPath) {
  let p = String(rawPath).replace(/\\/g, '/').replace(/\/+$/, '');
  for (;;) {
    const cut = p.lastIndexOf('/');
    if (cut <= 0) return '';
    p = p.slice(0, cut);
    try { if (existsSync(join(p, '.git'))) return p; } catch { /* unreadable: keep walking */ }
  }
}

function scopeAllows(armedCwd, curCwdRaw) {
  if (!norm(armedCwd)) return true;
  const a = norm(canon(armedCwd));
  const cRaw = canon(curCwdRaw);
  const c = norm(cRaw);
  if (!c) return false;
  if (norm(curCwdRaw) !== c) {
    const rawRepo = rawEnclosingRepo(curCwdRaw);
    if (rawRepo && norm(canon(rawRepo)) !== a) return false;
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

// Read the hook payload (source + cwd).
let payload = {};
try {
  const raw = readFileSync(0, 'utf8');
  if (raw && raw.trim()) payload = JSON.parse(raw);
} catch { /* ignore */ }

const now = Math.floor(Date.now() / 1000);
try { sweep(now); } catch { /* a sweep failure must never break session start */ }

if (payload.source !== 'clear') noop();   // non-clear, or no evidence of one

// Candidate arms: fresh, and armed in this project.
const candidates = [];
for (const p of armPaths()) {
  const arm = readArm(p);
  if (!isFresh(arm, now)) continue;
  if (!scopeAllows(arm.cwd, payload.cwd)) continue;        // wrong project -> leave armed
  candidates.push({ path: p, arm });
}
if (!candidates.length) noop();

// Oldest first: when two sessions in one project clear in the order they armed,
// each gets its own checkpoint back. (Out-of-order clears can still mis-pair —
// nothing in the payload says which session is clearing. See SKILL.md.)
candidates.sort((x, y) => x.arm.armed_at - y.arm.armed_at || x.path.localeCompare(y.path));

let chosen = null;
for (const c of candidates) {
  const cp = winPath(c.arm.checkpoint);
  let body = '';
  try { if (cp && existsSync(cp)) body = readFileSync(cp, 'utf8'); } catch { /* ignore */ }
  if (body.trim()) { chosen = { path: c.path, arm: c.arm, cp, body }; break; }
  drop(c.path);            // checkpoint gone: the flag is dead. The file is not.
}
if (!chosen) noop();

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
if (chosen.arm.branch) confirmLine += title ? ` (${chosen.arm.branch})` : ` (branch: ${chosen.arm.branch})`;

const header =
  '## Restored working context (/context-cycle)\n' +
  'The previous conversation was saved and cleared via /context-cycle to free the ' +
  'context window. Below is the saved working state — resume from the "Remaining ' +
  'Work" section and do not repeat work already marked done.\n' +
  (chosen.arm.branch ? `Saved on branch: ${chosen.arm.branch}\n` : '') +
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
