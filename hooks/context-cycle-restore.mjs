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

import { readFileSync, readdirSync, statSync, lstatSync, existsSync, unlinkSync, writeSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const TTL_SECONDS = 3600; // a flag older than this is stale -> ignored + cleared

const claudeDir = (process.env.CLAUDE_CONFIG_DIR || '').trim() || join(homedir(), '.claude');
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

// armed.d must be a real directory. readdirSync + unlinkSync(join(armDir, name))
// resolve through a symlink, so a symlinked armed.d would make this hook enumerate
// and DELETE *.json out of whatever directory the link points at. Treat that as
// "no per-session arms" and never read or unlink through it. (uninstall.sh's
// `rm -rf` on the same path is safe by contrast — rm removes a symlink without
// recursing into its target.)
function armDirUsable() {
  try { return lstatSync(armDir).isDirectory(); } catch { return false; }
}

// Every arm-flag file on disk: the per-(project, session) files plus a legacy
// single-slot armed.json if one is still lying around.
function armPaths() {
  const out = [];
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
function scopeAllows(armedCwd, curCwdRaw) {
  const a = norm(armedCwd);
  if (!a) return true;
  const c = norm(curCwdRaw);
  if (!c) return false;
  if (a === c) return true;
  if (!c.startsWith(a + '/')) return false;
  try { return !existsSync(join(String(curCwdRaw), '.git')); } catch { return true; }
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
