#!/usr/bin/env node
// SessionStart hook for the /context-cycle skill.
//
// Fires only when ALL of these hold:
//   (a) the session started from a real /clear (best-effort check),
//   (b) an "armed" flag written by /context-cycle exists and is fresh (< TTL),
//   (c) the current project matches the one the flag was armed in.
// On fire: inject the saved checkpoint as additionalContext (that IS the restore)
// and delete the flag (strictly one-shot).
//
// A /clear in a DIFFERENT project leaves the flag intact for the project it
// belongs to. An un-armed /clear, or any non-clear session start, is a silent
// no-op. This is why a generic /clear never restores anything.

import { readFileSync, existsSync, unlinkSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const TTL_SECONDS = 3600; // a flag older than this is stale -> ignored + cleared

const claudeDir = (process.env.CLAUDE_CONFIG_DIR || '').trim() || join(homedir(), '.claude');
const armedPath = join(claudeDir, 'context-cycle', 'armed.json');

function noop() { process.exit(0); }                 // no stdout => nothing injected
function disarm() { try { unlinkSync(armedPath); } catch { /* ignore */ } }

// Normalize a path for cross-tool comparison: backslashes -> '/', MSYS /c/ -> c:/,
// drop trailing slash, lowercase (Windows filesystem is case-insensitive).
function norm(p) {
  if (!p) return '';
  let s = String(p).replace(/\\/g, '/');
  const m = /^\/([a-zA-Z])\/(.*)$/.exec(s);
  if (m) s = m[1] + ':/' + m[2];
  return s.replace(/\/+$/, '').toLowerCase();
}

// Read the hook payload (source + cwd). If stdin can't be read we degrade
// gracefully: the armed-flag + TTL still gate, and the scope check is skipped.
let payload = {};
try {
  const raw = readFileSync(0, 'utf8');
  if (raw && raw.trim()) payload = JSON.parse(raw);
} catch { /* ignore */ }

if (payload.source && payload.source !== 'clear') noop();  // non-clear: never consume
if (!existsSync(armedPath)) noop();

let armed;
try {
  armed = JSON.parse(readFileSync(armedPath, 'utf8'));
} catch {
  disarm();
  noop();
}

const now = Math.floor(Date.now() / 1000);
if (!armed || typeof armed.armed_at !== 'number' || now - armed.armed_at > TTL_SECONDS) {
  disarm();                                          // stale -> clear it
  noop();
}

// Project scope: only restore in the project the flag was armed in. If the
// current cwd is unknown (stdin unreadable), skip the check rather than break.
const curCwd = norm(payload.cwd);
const armedCwd = norm(armed.cwd);
if (armedCwd && curCwd && curCwd !== armedCwd && !curCwd.startsWith(armedCwd + '/')) {
  noop();                                            // wrong project -> leave it armed
}

// Passed every gate: this is the restore. Consume, then inject.
disarm();

let cp = armed.checkpoint;
if (process.platform === 'win32' && typeof cp === 'string') {
  const m = /^\/([a-zA-Z])\/(.*)$/.exec(cp);         // /c/... -> C:/...
  if (m) cp = m[1].toUpperCase() + ':/' + m[2];
}
if (!cp || !existsSync(cp)) noop();

let body = '';
try { body = readFileSync(cp, 'utf8'); } catch { noop(); }
if (!body.trim()) noop();

// additionalContext is capped (~10k chars). Leave headroom; if the checkpoint is
// bigger, inject a head slice and point at the full file on disk.
const MAX = 9000;
let note = '';
if (body.length > MAX) {
  body = body.slice(0, MAX);
  note = `\n\n[...truncated. Full checkpoint on disk: ${cp}]`;
}

const header =
  '## Restored working context (/context-cycle)\n' +
  'The previous conversation was saved and cleared via /context-cycle to free the ' +
  'context window. Below is the saved working state — resume from the "Remaining ' +
  'Work" section and do not repeat work already marked done.\n' +
  (armed.branch ? `Saved on branch: ${armed.branch}\n` : '') +
  '\n---\n\n';

process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: 'SessionStart',
    additionalContext: header + body + note,
  },
}));
noop();
