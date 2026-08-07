#!/usr/bin/env bash
# Concurrency + regression suite for the /context-cycle machinery.
#
#   bash test/run-tests.sh
#
# Runs the repo's own arm.sh and restore hook against a throwaway
# CLAUDE_CONFIG_DIR in a temp dir — it never reads or writes your real
# ~/.claude, and it never touches an installed copy. Requires bash, node, git.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ARM="$REPO/context-cycle/arm.sh"
HOOK="$REPO/hooks/context-cycle-restore.mjs"

command -v node >/dev/null 2>&1 || { echo "node is required" >&2; exit 2; }
command -v git  >/dev/null 2>&1 || { echo "git is required"  >&2; exit 2; }
[ -f "$ARM"  ] || { echo "missing $ARM"  >&2; exit 2; }
[ -f "$HOOK" ] || { echo "missing $HOOK" >&2; exit 2; }

# Guard the scratch dir before anything uses it. With no `set -e`, a failed
# mktemp would leave ROOT empty, silently pointing CLAUDE_CONFIG_DIR at the real
# path /cfg — harmless as a normal user, but this suite writes and deletes files,
# and CI containers run as root.
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/context-cycle-test.XXXXXX")" || ROOT=""
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "mktemp -d failed; refusing to run" >&2; exit 2; }
trap 'rm -rf "$ROOT"' EXIT

# Path form for anything handed to node or written into an arm flag. The restore
# hook runs under NATIVE Windows node even when this suite runs in Git Bash, and
# native node cannot resolve an MSYS path: /tmp/x is not C:\tmp\x. Claude Code
# sends native-form cwd on Windows, so the suite must too — otherwise every scope
# check compares /tmp/... against C:/Users/.../Temp/... and nothing ever restores.
# A no-op on Linux and macOS, where cygpath does not exist.
winp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

CLAUDE_CONFIG_DIR="$(winp "$ROOT/cfg")"
export CLAUDE_CONFIG_DIR
ARMD="$CLAUDE_CONFIG_DIR/context-cycle/armed.d"

# Checkpoints go where the skill actually writes them. The hook confines the
# `checkpoint` field to the directories checkpoints are written to, so a suite that
# scattered them across the temp root — as this one did — would either fail wholesale
# or have to run with the escape hatch permanently open, which would leave the default
# roots untested across every group. Putting them here instead means all ~150
# assertions exercise the derived standalone root, and group 22 can test the policy
# itself. It also closes a fidelity gap that predates the policy: nothing in the suite
# used to arm from a path the skill would ever produce.
CPD="$CLAUDE_CONFIG_DIR/context-cycle/checkpoints"
mkdir -p "$CPD"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

# A skipped group is reported by name and re-listed in the summary. A suite that
# quietly drops a third of itself on one platform reads as full coverage.
SKIP=0; SKIPPED=""
skip() { SKIP=$((SKIP+1)); SKIPPED="$SKIPPED
  - $1 — $2"; printf '  SKIP %s\n       reason: %s\n' "$1" "$2"; }

# Age a file past the hook's LITTER_TTL_SECONDS (7 days), creating it first if absent.
# node, not `touch -d '8 days ago'`: that form is GNU-only (BSD/macOS touch has no -d
# like it), and node is already a hard requirement of the hook under test.
#
# This used to be 3 hours, against the old 3600s arm TTL. That number is now far too
# small and the groups below would pass VACUOUSLY with it: 14a and 15 assert that the
# sweep does not delete through a symlinked armed.d, and both depend on the victim file
# being reapable in the first place — a file the sweep would spare anyway proves
# nothing about the guard. Keep this comfortably past the litter horizon.
age() { [ -e "$1" ] || : > "$1"; node -e 'const t = Date.now()/1000 - 691200; require("fs").utimesSync(process.argv[1], t, t)' "$1"; }

# Count lines on stdin. BSD `wc -l` pads its output with leading spaces and GNU does
# not, so a bare `$(... | wc -l)` compared against a literal "1" passes on Linux and
# fails on macOS with the gloriously unhelpful `expected: 1 / actual:          1`.
# Two call sites had `tr -d ' '` and four did not; every count goes through here now
# so the next one cannot be added without it.
count() { wc -l | tr -d ' '; }

# Capability probes for the hostile-state groups — probed, not branched on `uname`,
# and the difference is not academic. The symlink probe does fire on Git Bash, which
# turns `ln -s` into a plain copy without MSYS=winsymlinks:nativestrict. The odd-names
# one does not: `o\vd"d` creates fine there and group 14b passes on the Windows CI job,
# so the confident claim this comment used to make about NTFS rejecting '"' and control
# bytes was simply wrong, and only running the probe caught it.
CAN_SYMLINK=0
ln -s "$ROOT" "$ROOT/.symprobe" 2>/dev/null && [ -L "$ROOT/.symprobe" ] && CAN_SYMLINK=1
rm -f "$ROOT/.symprobe" 2>/dev/null
# Hardlinks are a separate capability from symlinks and fail for different reasons —
# FAT32, some container overlay mounts, and a Git Bash without the NTFS privilege.
# Group 24 needs one to prove the ctime ordering survives a link(), which is the
# reason a hardlink is NOT refused where a symlink is.
CAN_HARDLINK=0
: > "$ROOT/.hardsrc" 2>/dev/null
ln "$ROOT/.hardsrc" "$ROOT/.hardprobe" 2>/dev/null && [ -f "$ROOT/.hardprobe" ] && CAN_HARDLINK=1
rm -f "$ROOT/.hardsrc" "$ROOT/.hardprobe" 2>/dev/null
CAN_ODD_NAMES=0
ODDPROBE="$ROOT/$(printf 'o\vd"d')"
: > "$ODDPROBE" 2>/dev/null && [ -f "$ODDPROBE" ] && CAN_ODD_NAMES=1
rm -f "$ODDPROBE" 2>/dev/null
# Whether two paths differing only in case are two directories or one. NTFS and the
# default macOS volume say one, so the case-collision group cannot run there — there
# is no second project for the arm to leak into.
CASE_SENSITIVE=0
mkdir -p "$ROOT/.CaseProbe" 2>/dev/null
[ -d "$ROOT/.caseprobe" ] || CASE_SENSITIVE=1
rm -rf "$ROOT/.CaseProbe" "$ROOT/.caseprobe" 2>/dev/null
# Whether a backslash can be an ordinary character in a directory name. It can on
# POSIX and cannot on Windows, where it is the separator — which is exactly why the
# hook must only collapse it there. Separate from CAN_ODD_NAMES: that probes '"' and
# control bytes, and a volume could accept one set and not the other — measured, since
# Git Bash accepts the odd names it was assumed to reject.
# The `.bs` check is what makes this a real probe rather than a tautology: where the
# backslash is a separator, `mkdir -p` cheerfully creates a NESTED `.bs/probe` and the
# `-d` test on the same string then passes for entirely the wrong reason. A literal
# one-component name leaves no `.bs` behind; a split one does.
CAN_BACKSLASH_NAME=0
mkdir -p "$ROOT/.bs\\probe" 2>/dev/null
[ -d "$ROOT/.bs\\probe" ] && [ ! -d "$ROOT/.bs" ] && CAN_BACKSLASH_NAME=1
rm -rf "$ROOT/.bs\\probe" "$ROOT/.bs" 2>/dev/null

# Group 8e used to be gated on a CAN_NESTED_SCOPE probe here, because a project nested
# inside another repo was refused wherever the clearing cwd's raw and canonical forms
# differed — true on macOS (/var -> /private/var) and Windows CI (8.3 short names),
# false on Linux, so the group could only assert on Linux. scopeAllows() now asks
# whether the resolved cwd stayed inside the raw path's enclosing repo rather than
# whether that repo IS the armed project, so the gate is gone and 8e runs everywhere.
# Group 19b covers the fix directly, with a symlink so it reproduces on any platform.

# Pull one field out of the hook's JSON stdout. node, not python — node is
# already a hard requirement of the hook itself, so the suite adds no new dep.
jsonf() { node -e '
  let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
    // additionalContext is optional: a refusal (group 22) is a systemMessage and
    // nothing else, because there is no context to inject and a hookSpecificOutput
    // carrying an undefined field is a worse thing to hand the consumer than none.
    const d = JSON.parse(s), ac = (d.hookSpecificOutput || {}).additionalContext || "";
    if (process.argv[1] === "banner") console.log(d.systemMessage);
    else console.log(d.hookSpecificOutput.hookEventName, ac.length > 4000,
                     ac.includes("truncated"), d.systemMessage.includes("BIG"));
  });' "$1"; }

# Restore banner reported by a /clear in $1 (cwd). '' when the hook stays silent.
# The payload is built with JSON.stringify, not printf, because a cwd containing a
# backslash or a quote is not JSON-safe as a raw substitution — `\r` in a directory
# name becomes a carriage return and the hook sees a path that does not exist. That
# is not a hypothetical: it silently turned a real scope-check bypass into a green
# assertion during development. Claude Code serialises the payload properly, so this
# is also the more faithful fixture.
clear_in() {
  local out
  out=$(node -e 'process.stdout.write(JSON.stringify({source:"clear",cwd:process.argv[1],session_id:"post-clear-new-uuid"}))' "$(winp "$1")" | node "$HOOK")
  [ -z "$out" ] && { echo ""; return; }
  printf '%s' "$out" | jsonf banner
}
# Raw hook stdout for a synthetic payload on stdin.
hook_raw() { node "$HOOK"; }
# A checkpoint-root refusal, collapsed to one token so the assertion reads as intent.
# Anything else comes back as the raw banner rather than a bare 0, so a failure shows
# what actually happened — including the ''  that means the hook stayed silent, which
# is a different bug (a refusal the user never sees) and must not look like a pass.
refused_in() {
  local b; b=$(clear_in "$1")
  case "$b" in
    "⚠ "*"outside the known"*) echo "refused" ;;
    *) echo "$b" ;;
  esac
}
# Group 24's banner carries a restore receipt AND a warning in one systemMessage, so
# the exact-match style used everywhere else would conflate the two. Split them:
# restored_line() is the receipt or '' when nothing was restored (a warning-only banner
# must never read as a restore), odd_note() is whether the not-a-regular-file warning
# was there at all — the point being that a refusal is reported rather than silent.
restored_line() { case "$1" in '✓ Restored'*) printf '%s\n' "$1" | head -1 ;; *) echo "" ;; esac; }
odd_note() { case "$1" in *"not a regular file"*) echo "warned" ;; *) echo "silent" ;; esac; }
mkcp() { printf '## Working on: %s\n\n### Remaining Work\n1. finish %s\n' "$2" "$2" > "$1"; }
mkproj() { mkdir -p "$1"; git -C "$1" init -q -b testbr 2>/dev/null; git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null; }
# Count arm flags by glob rather than `ls | grep -c` (SC2010): the glob asks the shell
# the question directly instead of pattern-matching ls output, and it drops the `|| true`
# that was only there to swallow grep's exit 1 on a zero count.
arms() { local n=0 f; for f in "$ARMD"/*.json; do [ -e "$f" ] && n=$((n+1)); done; echo "$n"; }

echo "=== 1. THE REPORTED BUG: two sessions, same project, interleaved ==="
P="$ROOT/p1"; mkproj "$P"
A="$CPD/p1-A.md"; B="$CPD/p1-B.md"; mkcp "$A" "ALPHA"; mkcp "$B" "BRAVO"
# Session A Step 1+2, Session B Step 1+2 (interleaved), then A Step 3, then B Step 3.
(cd "$P" && CLAUDE_CODE_SESSION_ID=aaaa-1111 bash "$ARM" "$A" >/dev/null 2>&1)
sleep 1
(cd "$P" && CLAUDE_CODE_SESSION_ID=bbbb-2222 bash "$ARM" "$B" >/dev/null 2>&1)
eq "both arms coexist (no clobber)" "2" "$(arms)"
eq "first /clear restores ALPHA"  '✓ Restored: "ALPHA" · next: finish ALPHA (testbr)' "$(clear_in "$P")"
eq "second /clear restores BRAVO" '✓ Restored: "BRAVO" · next: finish BRAVO (testbr)' "$(clear_in "$P")"
eq "no arms left"                 "0" "$(arms)"
eq "third /clear is a no-op"      "" "$(clear_in "$P")"

echo "=== 2. Two sessions, DIFFERENT projects ==="
PA="$ROOT/p2a"; PB="$ROOT/p2b"; mkproj "$PA"; mkproj "$PB"
CA="$CPD/p2a.md"; CB="$CPD/p2b.md"; mkcp "$CA" "PROJ-A"; mkcp "$CB" "PROJ-B"
(cd "$PA" && CLAUDE_CODE_SESSION_ID=s-a bash "$ARM" "$CA" >/dev/null 2>&1)
(cd "$PB" && CLAUDE_CODE_SESSION_ID=s-b bash "$ARM" "$CB" >/dev/null 2>&1)
eq "two project arms coexist" "2" "$(arms)"
eq "clear in A gets PROJ-A" '✓ Restored: "PROJ-A" · next: finish PROJ-A (testbr)' "$(clear_in "$PA")"
eq "B's arm survives A's clear" "1" "$(arms)"
eq "clear in B gets PROJ-B" '✓ Restored: "PROJ-B" · next: finish PROJ-B (testbr)' "$(clear_in "$PB")"

echo "=== 3. Single-session baseline (must not break) ==="
P3="$ROOT/p3"; mkproj "$P3"; C3="$CPD/p3.md"; mkcp "$C3" "SOLO"
(cd "$P3" && CLAUDE_CODE_SESSION_ID=solo-1 bash "$ARM" "$C3" >/dev/null 2>&1)
eq "solo restore fires"   '✓ Restored: "SOLO" · next: finish SOLO (testbr)' "$(clear_in "$P3")"
eq "one-shot: 2nd is no-op" "" "$(clear_in "$P3")"

echo "=== 4. Re-arm in the SAME session supersedes (newest wins, no accumulation) ==="
P4="$ROOT/p4"; mkproj "$P4"; O="$CPD/p4-old.md"; N="$CPD/p4-new.md"
mkcp "$O" "STALE-DRAFT"; mkcp "$N" "REDONE"
(cd "$P4" && CLAUDE_CODE_SESSION_ID=same-sess bash "$ARM" "$O" >/dev/null 2>&1)
sleep 1
(cd "$P4" && CLAUDE_CODE_SESSION_ID=same-sess bash "$ARM" "$N" >/dev/null 2>&1)
eq "still exactly one arm" "1" "$(arms)"
eq "newest checkpoint wins" '✓ Restored: "REDONE" · next: finish REDONE (testbr)' "$(clear_in "$P4")"

echo "=== 5. Legacy single-slot armed.json (session mid-cycle when this lands) ==="
P5="$ROOT/p5"; mkproj "$P5"; C5="$CPD/p5.md"; mkcp "$C5" "LEGACY"
cat > "$CLAUDE_CONFIG_DIR/context-cycle/armed.json" <<EOF
{ "checkpoint": "$(winp "$C5")", "branch": "testbr", "cwd": "$(winp "$P5")", "armed_at": $(date +%s) }
EOF
# "testbr", not "main": mkproj inits on testbr, and a real legacy flag recorded the
# branch it was actually armed on. Hard-coding a different one here made this group
# trip the branch-drift disclosure and assert two unrelated things at once.
eq "legacy arm is consumed" '✓ Restored: "LEGACY" · next: finish LEGACY (testbr)' "$(clear_in "$P5")"
eq "legacy file deleted" "absent" "$([ -e "$CLAUDE_CONFIG_DIR/context-cycle/armed.json" ] && echo present || echo absent)"

echo "=== 6. Corrupt / old-format garbage never crashes ==="
printf 'not json at all {{{' > "$CLAUDE_CONFIG_DIR/context-cycle/armed.json"
OUT=$(printf '{"source":"clear","cwd":"%s"}' "$(winp "$P5")" | node "$HOOK" 2>"$ROOT/err6"); RC=$?
eq "exit 0 on garbage" "0" "$RC"
eq "no stdout on garbage" "" "$OUT"
eq "no stderr on garbage" "" "$(cat "$ROOT/err6")"
age "$CLAUDE_CONFIG_DIR/context-cycle/armed.json"
printf '{"source":"startup","cwd":"%s"}' "$(winp "$P5")" | node "$HOOK" >/dev/null 2>&1
eq "old garbage reaped by sweep" "absent" "$([ -e "$CLAUDE_CONFIG_DIR/context-cycle/armed.json" ] && echo present || echo absent)"

echo "=== 7. arm.sh rejects everything that used to silently fall back ==="
P7="$ROOT/p7"; mkproj "$P7"; C7="$CPD/p7.md"; mkcp "$C7" "GOOD"
# shellcheck disable=SC2069  # The order is deliberate: stderr to the capture, stdout to
# /dev/null. arm.sh writes its refusals to stderr and these assertions read the message.
try() { (cd "$P7" && bash "$ARM" "$1" 2>&1 >/dev/null); }
rc()  { (cd "$P7" && bash "$ARM" "$1" >/dev/null 2>&1); echo $?; }
eq "no arg at all -> rc 1"      "1" "$( (cd "$P7" && bash "$ARM" >/dev/null 2>&1); echo $? )"
eq "no arg message"             "arm.sh: missing checkpoint path." "$( (cd "$P7" && bash "$ARM" 2>&1 >/dev/null) | head -1 )"
eq "empty string -> rc 1"       "1" "$(rc '')"
eq "whitespace only -> rc 1"    "1" "$(rc '   ')"
eq "literal \$FILE -> rc 1"     "1" "$(rc '$FILE')"
eq "\$FILE message names the cause" "arm.sh: argument looks like an unexpanded shell variable: \$FILE" "$(try '$FILE' | head -1)"
eq "relative path -> rc 1"      "1" "$(rc 'notes/cp.md')"
eq "missing file -> rc 1"       "1" "$(rc '/nope/gone.md')"
: > "$CPD/empty.md"
eq "empty checkpoint -> rc 1"   "1" "$(rc "$CPD/empty.md")"
eq "nothing got armed by any of those" "0" "$(arms)"
eq "valid path -> rc 0"         "0" "$(rc "$C7")"
eq "and it armed"               "1" "$(arms)"
# The MSYS /c/ -> C:/ rewrite must not fire on POSIX: it used to mangle any
# checkpoint under a single-letter top-level directory (/a/x.md -> A:/x.md) into a
# path the hook then cannot read. Round-trip fidelity for an ordinary path is the
# part CI can reach; see TODOS.md for why the /a/ case itself is not testable here.
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*)
    skip "group 7 checkpoint-verbatim assertion" "on Windows the flag correctly stores the cygpath -m form, not the MSYS input" ;;
  *)
    eq "checkpoint stored verbatim (no path rewriting on POSIX)" "$C7" \
       "$(node -e 'const fs=require("fs"),p=require("path");const d=process.argv[1];
          const f=fs.readdirSync(d).filter(n=>n.endsWith(".json"))[0];
          console.log(JSON.parse(fs.readFileSync(p.join(d,f),"utf8")).checkpoint)' "$ARMD")" ;;
esac
rm -f "$ARMD"/*.json

echo "=== 8. Arms do not expire; staleness is disclosed instead ==="
# This group used to assert the exact opposite ("a stale arm is swept, never
# restored"). The bound was wrong, not the assertion: closing the editor and clearing
# the next day is the normal way to use this, and the 3600s TTL swept the arm, left
# the /clear looking like any other, and told the user nothing about why their context
# never came back. The hazard the bound was aimed at is real but is a DISCLOSURE
# problem, not a lifetime one — see the age/drift assertions below.
P8="$ROOT/p8"; mkproj "$P8"; C8="$CPD/p8.md"; mkcp "$C8" "OLD"
mkdir -p "$ARMD"
arm8() {  # $1 = seconds of age, $2 = branch recorded in the flag
  rm -f "$ARMD"/*.json
  cat > "$ARMD/deadbeef1234-oldsess.json" <<EOF
{ "checkpoint": "$(winp "$C8")", "branch": "$2", "cwd": "$(winp "$P8")", "armed_at": $(( $(date +%s) - $1 )) }
EOF
}
# Two hours: dead under the old TTL, and the case that started this.
arm8 7200 ""
eq "2h-old arm restores"        '✓ Restored: "OLD" · next: finish OLD' "$(clear_in "$P8")"
eq "and is consumed"            "0" "$(arms)"
# Thirty days. Nothing special about the number — it is well past any bound anyone
# would have picked, which is the point of asserting it rather than a second short age.
arm8 2592000 ""
eq "30d-old arm still restores, age disclosed" \
   '✓ Restored: "OLD" · next: finish OLD · 30d old' "$(clear_in "$P8")"
# A young arm must NOT get the age suffix, or the disclosure is noise on every cycle.
arm8 600 ""
eq "10m-old arm says nothing about age" '✓ Restored: "OLD" · next: finish OLD' "$(clear_in "$P8")"
# armed_at is still required: it orders concurrent arms, so a flag without a usable
# one is malformed rather than eternal. Reaped on sight, not kept forever.
rm -f "$ARMD"/*.json
cat > "$ARMD/deadbeef1234-nostamp.json" <<EOF
{ "checkpoint": "$(winp "$C8")", "branch": "", "cwd": "$(winp "$P8")", "armed_at": "not-a-number" }
EOF
eq "arm with unusable armed_at does not restore" "" "$(clear_in "$P8")"
eq "and is swept"               "0" "$(arms)"
# Opt-in bound. CONTEXT_CYCLE_TTL exists for anyone who would rather a forgotten arm
# self-destruct; setting it must reproduce the old behaviour exactly.
arm8 7200 ""
eq "CONTEXT_CYCLE_TTL=3600 sweeps the 2h arm" "" "$(CONTEXT_CYCLE_TTL=3600 clear_in "$P8")"
eq "and it is gone from disk"   "0" "$(arms)"
arm8 7200 ""
eq "CONTEXT_CYCLE_TTL=86400 keeps it" '✓ Restored: "OLD" · next: finish OLD' "$(CONTEXT_CYCLE_TTL=86400 clear_in "$P8")"
# Junk and zero must mean "no bound", not "expires immediately" — a blank-but-present
# env var is the classic way a config value arrives, and failing closed here would
# silently disarm every restore on machines that export it empty.
arm8 7200 ""
eq "CONTEXT_CYCLE_TTL=0 means no bound"     '✓ Restored: "OLD" · next: finish OLD' "$(CONTEXT_CYCLE_TTL=0 clear_in "$P8")"
arm8 7200 ""
eq "CONTEXT_CYCLE_TTL=junk means no bound"  '✓ Restored: "OLD" · next: finish OLD' "$(CONTEXT_CYCLE_TTL=wat clear_in "$P8")"
arm8 7200 ""
eq "CONTEXT_CYCLE_TTL='' means no bound"    '✓ Restored: "OLD" · next: finish OLD' "$(CONTEXT_CYCLE_TTL='' clear_in "$P8")"

echo "=== 8b. Branch drift is disclosed to the user AND to the model ==="
# The one way a never-expiring arm bites: the checkpoint describes a branch that has
# since moved on, and the header's own "resume from this, do not repeat work already
# marked done" framing makes it read as current. Both output channels must say so —
# the banner is all the user sees, the additionalContext is all the model sees.
P8B="$ROOT/p8b"; mkproj "$P8B"; C8B="$CPD/p8b.md"; mkcp "$C8B" "DRIFT"
(cd "$P8B" && CLAUDE_CODE_SESSION_ID=drift-1 bash "$ARM" "$C8B" >/dev/null 2>&1)
git -C "$P8B" checkout -q -b moved 2>/dev/null
eq "banner names the branch we are on now" \
   '✓ Restored: "DRIFT" · next: finish DRIFT (testbr) · now on moved' "$(clear_in "$P8B")"
(cd "$P8B" && CLAUDE_CODE_SESSION_ID=drift-2 bash "$ARM" "$C8B" >/dev/null 2>&1)
git -C "$P8B" checkout -q -b moved-again 2>/dev/null
DRIFTCTX=$(node -e 'process.stdout.write(JSON.stringify({source:"clear",cwd:process.argv[1]}))' "$(winp "$P8B")" \
  | node "$HOOK" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      const a=JSON.parse(s).hookSpecificOutput.additionalContext;
      console.log(a.includes("The branch has changed since this was saved") &&
                  a.includes("`moved-again`") ? "warned" : "SILENT")})')
eq "model context carries the drift warning" "warned" "$DRIFTCTX"
# No drift, no line: the same-branch cycle is the common case and must stay clean.
(cd "$P8B" && CLAUDE_CODE_SESSION_ID=drift-3 bash "$ARM" "$C8B" >/dev/null 2>&1)
eq "same branch says nothing about drift" \
   '✓ Restored: "DRIFT" · next: finish DRIFT (moved-again)' "$(clear_in "$P8B")"
rm -f "$ARMD"/*.json

echo "=== 8c. arm.sh must not reap another project's waiting arm ==="
# The second place the expiry lived, and the one that would have silently undone the
# fix if only the hook had been changed. armed.d/ is shared across every project and
# arm.sh cannot parse JSON to tell a live arm from litter, so its old
# `find -name '*.json' ... -mmin +60 -delete` deleted any arm older than an hour
# whenever ANY project armed a cycle. Arming in project B ate project A's pending
# restore. Litter collection still has to work, hence the .tmp assertion.
P8C="$ROOT/p8c"; mkproj "$P8C"; C8C="$CPD/p8c.md"; mkcp "$C8C" "PATIENT"
P8D="$ROOT/p8d"; mkproj "$P8D"; C8D="$CPD/p8d.md"; mkcp "$C8D" "OTHER"
rm -f "$ARMD"/*.json
cat > "$ARMD/aaaa1111-patient.json" <<EOF
{ "checkpoint": "$(winp "$C8C")", "branch": "testbr", "cwd": "$(winp "$P8C")", "armed_at": $(( $(date +%s) - 691200 )) }
EOF
age "$ARMD/aaaa1111-patient.json"
: > "$ARMD/.tmp.abandoned"; age "$ARMD/.tmp.abandoned"
(cd "$P8D" && CLAUDE_CODE_SESSION_ID=other-sess bash "$ARM" "$C8D" >/dev/null 2>&1)
eq "an 8d-old arm survives another project arming" "present" \
   "$([ -e "$ARMD/aaaa1111-patient.json" ] && echo present || echo GONE)"
eq "abandoned temp file IS still reaped" "absent" \
   "$([ -e "$ARMD/.tmp.abandoned" ] && echo present || echo absent)"
eq "and the 8d-old arm still restores" \
   '✓ Restored: "PATIENT" · next: finish PATIENT (testbr) · 8d old' "$(clear_in "$P8C")"
rm -f "$ARMD"/*.json

echo "=== 8d. A branch name is untrusted input and must not reach the model raw ==="
# Drift disclosure put a branch name into the model-facing header inside a code span.
# Git permits a backtick in a ref (only ~^:?*[ , control chars and a few structural
# rules are rejected — `git checkout -b 'fix`x`y'` really does land verbatim in
# .git/HEAD), and checking out a fork's PR branch to review it is an ordinary thing to
# do. So an unescaped name closes the span and injects into a context the model is told
# to "resume from". HEAD is written directly here rather than via `git checkout -b` so
# the assertion tests the hook, not whether the filesystem tolerates the ref filename.
P8F="$ROOT/p8f"; mkproj "$P8F"; C8F="$CPD/p8f.md"; mkcp "$C8F" "HOSTILE"
(cd "$P8F" && CLAUDE_CODE_SESSION_ID=hostile-1 bash "$ARM" "$C8F" >/dev/null 2>&1)
printf 'ref: refs/heads/pr-42`IGNORE`\n' > "$P8F/.git/HEAD"
eq "banner neutralizes a hostile branch name" \
   '✓ Restored: "HOSTILE" · next: finish HOSTILE (testbr) · now on pr-42?IGNORE?' "$(clear_in "$P8F")"
(cd "$P8F" && CLAUDE_CODE_SESSION_ID=hostile-2 bash "$ARM" "$C8F" >/dev/null 2>&1)
printf 'ref: refs/heads/pr-42`IGNORE`\n' > "$P8F/.git/HEAD"
HOSTCTX=$(node -e 'process.stdout.write(JSON.stringify({source:"clear",cwd:process.argv[1]}))' "$(winp "$P8F")" \
  | node "$HOOK" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      const a=JSON.parse(s).hookSpecificOutput.additionalContext;
      // The sanitized name must be there, and the span must not be closable through it.
      console.log(a.includes("`pr-42?IGNORE?`") && !a.includes("IGNORE`") ? "escaped" : "RAW")})')
eq "model context carries no unescaped backtick" "escaped" "$HOSTCTX"
# The same treatment for the branch recorded in the arm flag. Lower severity — writing
# a flag needs access to the config dir — but it lands in the same header.
rm -f "$ARMD"/*.json
cat > "$ARMD/aaaa3333-flag.json" <<EOF
{ "checkpoint": "$(winp "$C8F")", "branch": "a\`b*c", "cwd": "$(winp "$P8F")", "armed_at": $(date +%s) }
EOF
eq "a hostile branch inside the arm flag is neutralized too" \
   '✓ Restored: "HOSTILE" · next: finish HOSTILE (a?b?c) · now on pr-42?IGNORE?' "$(clear_in "$P8F")"

echo "=== 8e. A worktree/submodule .git FILE reports no branch, not the parent's ==="
# Drift disclosure is only worth trusting if a wrong branch is impossible. A linked
# worktree or a submodule has a `.git` FILE pointing at a gitdir elsewhere; walking
# past it finds the superproject's `.git` DIRECTORY and reports ITS branch, which
# fabricates drift (or hides real drift) rather than staying quiet.
P8E="$ROOT/p8e"; mkproj "$P8E"; C8E="$CPD/p8e.md"; mkcp "$C8E" "WORKTREE"
mkdir -p "$P8E/wt"; printf 'gitdir: %s/.git/worktrees/wt\n' "$P8E" > "$P8E/wt/.git"
rm -f "$ARMD"/*.json
cat > "$ARMD/aaaa4444-wt.json" <<EOF
{ "checkpoint": "$(winp "$C8E")", "branch": "feat/elsewhere", "cwd": "$(winp "$P8E/wt")", "armed_at": $(date +%s) }
EOF
eq "no drift claimed from a parent repo's branch" \
   '✓ Restored: "WORKTREE" · next: finish WORKTREE (feat/elsewhere)' "$(clear_in "$P8E/wt")"
rm -f "$ARMD"/*.json

echo "=== 9. Non-clear session starts never consume the arm ==="
P9="$ROOT/p9"; mkproj "$P9"; C9="$CPD/p9.md"; mkcp "$C9" "KEEP"
(cd "$P9" && CLAUDE_CODE_SESSION_ID=s9 bash "$ARM" "$C9" >/dev/null 2>&1)
eq "source=startup: silent"  "" "$(printf '{"source":"startup","cwd":"%s"}' "$(winp "$P9")" | hook_raw)"
eq "source=resume: silent"   "" "$(printf '{"source":"resume","cwd":"%s"}' "$(winp "$P9")" | hook_raw)"
eq "source=compact: silent"  "" "$(printf '{"source":"compact","cwd":"%s"}' "$(winp "$P9")" | hook_raw)"
eq "arm survived all three"  "1" "$(arms)"

echo "=== 10. Unreadable/empty payload fails CLOSED (was: fired a restore) ==="
eq "empty stdin: silent"      "" "$(hook_raw < /dev/null)"
eq "garbage stdin: silent"    "" "$(printf 'not-json' | hook_raw)"
eq "payload with no source: silent" "" "$(printf '{"cwd":"%s"}' "$(winp "$P9")" | hook_raw)"
eq "arm still intact after all three" "1" "$(arms)"
eq "a real clear still works" '✓ Restored: "KEEP" · next: finish KEEP (testbr)' "$(clear_in "$P9")"

echo "=== 11. Project scope: subdirectories vs nested repos ==="
P11="$ROOT/p11"; mkproj "$P11"; mkdir -p "$P11/frontend" "$P11/vendor/lib"
git -C "$P11/vendor/lib" init -q 2>/dev/null            # nested repo = other project
C11="$CPD/p11.md"; mkcp "$C11" "MONO"
(cd "$P11" && CLAUDE_CODE_SESSION_ID=s11 bash "$ARM" "$C11" >/dev/null 2>&1)
eq "clear in a nested REPO does not fire" "" "$(clear_in "$P11/vendor/lib")"
eq "arm survives the nested-repo clear"   "1" "$(arms)"
eq "clear in a plain subdir does fire" '✓ Restored: "MONO" · next: finish MONO (testbr)' "$(clear_in "$P11/frontend")"
# unrelated project must never match
C11b="$CPD/p11b.md"; mkcp "$C11b" "MONO2"
(cd "$P11" && CLAUDE_CODE_SESSION_ID=s11b bash "$ARM" "$C11b" >/dev/null 2>&1)
eq "clear in an unrelated dir does not fire" "" "$(clear_in "$ROOT/p2a")"
eq "arm survives that too" "1" "$(arms)"
rm -f "$ARMD"/*.json

echo "=== 11b. A hand-written flag cannot claim every project, or jump the queue ==="
# Nothing here is reachable through arm.sh: every version of it writes
# `git rev-parse --show-toplevel || pwd` into cwd and `date +%s` into armed_at, so a
# flag missing the first or non-positive in the second was written by something else.
# Both used to be honoured — a missing cwd matched the NEXT /clear in any project at
# all, and armed_at:0 sorts ahead of every real arm. Together that is one flag that
# fires wherever the user happens to clear next and wins if a real arm is also
# waiting. Each assertion below fails against the pre-change hook.
P11c="$ROOT/p11c"; mkproj "$P11c"; C11c="$CPD/p11c.md"; mkcp "$C11c" "PLANTED"
plant() { printf '{ "checkpoint": "%s", "branch": "testbr", %s }\n' \
  "$(winp "$C11c")" "$2" > "$1"; }

# (a) cwd absent entirely -> refused, in a project that has nothing to do with it.
plant "$ARMD/zz-nocwd.json" "\"armed_at\": $(date +%s)"
eq "flag with NO cwd does not fire"        "" "$(clear_in "$P11c")"
eq "...and is left on disk, not consumed"  "1" "$(arms)"
rm -f "$ARMD"/*.json

# (b) the two shapes that reach the same fail-open branch by normalising to empty.
for shape in '"cwd": ""' '"cwd": "/"'; do
  plant "$ARMD/zz-empty.json" "$shape, \"armed_at\": $(date +%s)"
  eq "flag with $shape does not fire" "" "$(clear_in "$P11c")"
  rm -f "$ARMD"/*.json
done

# (c) the legacy single-slot file gets NO exemption. Group 5 covers the migration
# path that matters (a legacy flag WITH a cwd is still consumed); this asserts the
# exemption a reviewer suggested for it was not granted, because armed.json lives in
# the same directory an attacker would already be writing to.
plant "$CLAUDE_CONFIG_DIR/context-cycle/armed.json" "\"armed_at\": $(date +%s)"
eq "legacy armed.json with NO cwd does not fire" "" "$(clear_in "$P11c")"
rm -f "$CLAUDE_CONFIG_DIR/context-cycle/armed.json"

# (d) armed_at must be positive. Correct cwd this time, so scope is not what refuses.
for stamp in 0 -1; do
  plant "$ARMD/zz-stamp.json" "\"cwd\": \"$(winp "$P11c")\", \"armed_at\": $stamp"
  eq "flag with armed_at:$stamp does not fire" "" "$(clear_in "$P11c")"
  rm -f "$ARMD"/*.json
  # The reap is asserted on a NON-clear start, where no restore can consume the flag.
  # After a /clear it would read 0 on the pre-change hook too — because the flag FIRED
  # and was consumed — so the obvious version of this assertion passes vacuously and
  # proves nothing. Here the pre-change hook leaves the file sitting there.
  plant "$ARMD/zz-stamp.json" "\"cwd\": \"$(winp "$P11c")\", \"armed_at\": $stamp"
  printf '{"source":"startup","cwd":"%s"}' "$(winp "$P11c")" | node "$HOOK" >/dev/null 2>&1
  eq "...and a non-clear start sweeps it as malformed" "0" "$(arms)"
  rm -f "$ARMD"/*.json
done

# (e) the point of (d): a real arm in the same project must win, not merely coexist.
# Pre-change, armed_at:0 sorts first and PLANTED is restored instead of REAL.
C11d="$CPD/p11d.md"; mkcp "$C11d" "REAL"
(cd "$P11c" && CLAUDE_CODE_SESSION_ID=s11c bash "$ARM" "$C11d" >/dev/null 2>&1)
plant "$ARMD/zz-race.json" "\"cwd\": \"$(winp "$P11c")\", \"armed_at\": 0"
eq "a real arm beats a flag stamped 0" '✓ Restored: "REAL" · next: finish REAL (testbr)' "$(clear_in "$P11c")"
rm -f "$ARMD"/*.json

echo "=== 12. Vanished checkpoint: skip to the next arm, never delete a checkpoint ==="
P12="$ROOT/p12"; mkproj "$P12"
G="$CPD/p12-gone.md"; K="$CPD/p12-kept.md"; mkcp "$G" "GONE"; mkcp "$K" "KEPT"
(cd "$P12" && CLAUDE_CODE_SESSION_ID=s12a bash "$ARM" "$G" >/dev/null 2>&1)
sleep 1
(cd "$P12" && CLAUDE_CODE_SESSION_ID=s12b bash "$ARM" "$K" >/dev/null 2>&1)
rm -f "$G"                                   # user moved/deleted it out of band
eq "falls through to the live arm" '✓ Restored: "KEPT" · next: finish KEPT (testbr)' "$(clear_in "$P12")"
eq "both dead+used arms cleared" "0" "$(arms)"
BEFORE=$(ls -1 "$CPD"/*.md | count)
(cd "$P12" && CLAUDE_CODE_SESSION_ID=s12c bash "$ARM" "$K" >/dev/null 2>&1)
clear_in "$P12" >/dev/null
eq "checkpoint files never deleted by a restore" "$BEFORE" "$(ls -1 "$CPD"/*.md | count)"

echo "=== 13. Payload shape: full multi-KB checkpoint survives writeSync ==="
P13="$ROOT/p13"; mkproj "$P13"; C13="$CPD/p13.md"
{ printf '## Working on: BIG\n\n### Remaining Work\n1. finish BIG\n\n'
  for i in $(seq 1 400); do printf 'padding line %d with some prose to make this multi-KB\n' "$i"; done; } > "$C13"
(cd "$P13" && CLAUDE_CODE_SESSION_ID=s13 bash "$ARM" "$C13" >/dev/null 2>&1)
RES=$(printf '{"source":"clear","cwd":"%s"}' "$(winp "$P13")" | node "$HOOK" | jsonf shape)
eq "valid JSON, complete, truncation-noted" "SessionStart true true true" "$RES"
eq "checkpoint size on disk" "1" "$([ "$(wc -c < "$C13")" -gt 9000 ] && echo 1 || echo 0)"

echo "=== 14. Hostile state dir: symlinked armed.d, control chars in paths ==="
rm -f "$ARMD"/*.json
P14="$ROOT/p14"; mkproj "$P14"; C14="$CPD/p14.md"; mkcp "$C14" "SYM"
if [ "$CAN_SYMLINK" = 1 ]; then
# A symlinked armed.d must not become a delete-anything primitive: readdirSync +
# unlinkSync resolve through it, so the hook would reap *.json from the target.
# The target file must be past the litter horizon: sweep() only reaps an unparseable
# flag once it is that old, so a fresh file would survive even WITHOUT the guard and the
# assertion would pass vacuously.
VICTIM="$ROOT/victim"; mkdir -p "$VICTIM"; age "$VICTIM/precious.json"
mv "$ARMD" "$ARMD.real"; ln -s "$VICTIM" "$ARMD"
printf '{"source":"clear","cwd":"%s"}' "$(winp "$ROOT/p1")" | node "$HOOK" >/dev/null 2>&1
eq "hook does not delete through a symlinked armed.d" "present" \
   "$([ -e "$VICTIM/precious.json" ] && echo present || echo GONE)"
eq "arm.sh refuses a symlinked armed.d -> rc 1" "1" \
   "$( (cd "$P14" && bash "$ARM" "$C14" >/dev/null 2>&1); echo $? )"
eq "nothing written into the symlink target" "1" "$(ls -1 "$VICTIM" | count)"
rm -f "$ARMD"; mv "$ARMD.real" "$ARMD"
else
  skip "group 14a (symlinked armed.d)" "this shell/filesystem does not create real symlinks"
fi
if [ "$CAN_ODD_NAMES" = 1 ]; then
# A control byte in a path yields invalid JSON, which fails SILENTLY (no restore,
# no error) until the litter sweep reaps it a week later. arm.sh must reject it loudly.
NLCP="$CPD/$(printf 'we\vird').md"; mkcp "$NLCP" "CTRL" 2>/dev/null
eq "control char in checkpoint path -> rc 1" "1" \
   "$( (cd "$P14" && bash "$ARM" "$NLCP" >/dev/null 2>&1); echo $? )"
eq "and nothing was armed" "0" "$(arms)"
# esc() backstop: whatever reaches the flag, it must still be parseable JSON.
BR=$ROOT/'br"anch\test'; mkproj "$BR" 2>/dev/null
CBR="$CPD/br.md"; mkcp "$CBR" "QUOTES"
(cd "$BR" && CLAUDE_CODE_SESSION_ID=s14 bash "$ARM" "$CBR" >/dev/null 2>&1)
eq "quotes/backslashes in project path still emit valid JSON" "ok" \
   "$(node -e 'const fs=require("fs"),p=require("path");const d=process.argv[1];
      const f=fs.readdirSync(d).filter(n=>n.endsWith(".json"));
      if(!f.length){console.log("no flag");process.exit(0)}
      try{JSON.parse(fs.readFileSync(p.join(d,f[0]),"utf8"));console.log("ok")}
      catch(e){console.log("INVALID: "+e.message)}' "$ARMD")"
else
  skip "group 14b (control chars + quotes in paths)" "this filesystem rejects '\"' and control bytes in filenames"
fi
rm -f "$ARMD"/*.json

echo "=== 15. Symlinked ANCESTOR of armed.d (leaf-only checks miss this) ==="
if [ "$CAN_SYMLINK" != 1 ]; then
  skip "group 15 (symlinked ancestor)" "this shell/filesystem does not create real symlinks"
else
# A link at context-cycle/ resolves during traversal, so armed.d inside the target
# is a real directory and a leaf-only guard passes — the sweep then deletes out of
# the attacker's directory. Both levels below the config root must be checked.
R15="$ROOT/anc"; mkdir -p "$R15/cfg" "$R15/evil/armed.d"
age "$R15/evil/armed.d/precious.json"
ln -s "$R15/evil" "$R15/cfg/context-cycle"
P15="$ROOT/p15"; mkproj "$P15"; C15="$CPD/p15.md"; mkcp "$C15" "ANC"
eq "arm.sh refuses a symlinked context-cycle/ -> rc 1" "1" \
   "$( (cd "$P15" && CLAUDE_CONFIG_DIR="$(winp "$R15/cfg")" bash "$ARM" "$C15" >/dev/null 2>&1); echo $? )"
# Assert by NAME, not by count: the arm.sh of the day reaped the stale precious.json
# via its own `find -delete` and wrote a flag in its place, leaving the count at 1.
# That `find` no longer matches *.json at all, so this now guards two things at once.
eq "no flag written into the link target" "precious.json" \
   "$(ls -1 "$R15/evil/armed.d" | tr '\n' ' ' | sed 's/ *$//')"
CLAUDE_CONFIG_DIR="$(winp "$R15/cfg")" node "$HOOK" >/dev/null 2>&1 <<EOF
{"source":"clear","cwd":"$(winp "$P15")"}
EOF
eq "hook does not delete through a symlinked ancestor" "present" \
   "$([ -e "$R15/evil/armed.d/precious.json" ] && echo present || echo GONE)"
fi

echo "=== 16. A symlinked CONFIG ROOT stays supported (stow/chezmoi dotfiles) ==="
if [ "$CAN_SYMLINK" != 1 ]; then
  skip "group 16 (symlinked config root)" "this shell/filesystem does not create real symlinks"
else
# The guard above must not fire here: symlinking ~/.claude into a dotfiles repo is
# a normal setup, and refusing it would break the tool for those users.
R16="$ROOT/dot"; mkdir -p "$R16/real-claude"; ln -s "$R16/real-claude" "$R16/claude-link"
# Checkpoint written THROUGH the link, into that config root's own checkpoints dir.
# This is the shape the checkpoint-root policy has to get right for dotfiles users:
# the flag records the link spelling, the hook derives its roots from the resolved
# one, and the two only agree because both sides are canonicalized. Written via the
# link on purpose — writing to real-claude directly would compare like-for-like and
# prove nothing about that.
P16="$ROOT/p16"; mkproj "$P16"
mkdir -p "$R16/claude-link/context-cycle/checkpoints"
C16="$(winp "$R16/claude-link/context-cycle/checkpoints/p16.md")"; mkcp "$C16" "DOTFILES"
eq "arm.sh accepts a symlinked config root -> rc 0" "0" \
   "$( (cd "$P16" && CLAUDE_CONFIG_DIR="$(winp "$R16/claude-link")" CLAUDE_CODE_SESSION_ID=s16 bash "$ARM" "$C16" >/dev/null 2>&1); echo $? )"
eq "flag landed in the real dir" "1" \
   "$(ls -1 "$R16/real-claude/context-cycle/armed.d"/*.json 2>/dev/null | count)"
OUT16=$(CLAUDE_CONFIG_DIR="$(winp "$R16/claude-link")" node "$HOOK" <<EOF
{"source":"clear","cwd":"$(winp "$P16")"}
EOF
)
eq "restore still fires through a symlinked config root" \
   '✓ Restored: "DOTFILES" · next: finish DOTFILES (testbr)' \
   "$([ -n "$OUT16" ] && printf '%s' "$OUT16" | jsonf banner)"
fi

echo "=== 17. The cp fallback does not write through a symlinked destination ==="
if [ "$CAN_SYMLINK" != 1 ]; then
  skip "group 17 (cp fallback vs symlinked destination)" "this shell/filesystem does not create real symlinks"
else
# `mv` renames a directory entry and never dereferences an existing destination, so
# the primary write was always safe — asserting on it would pass against the old code
# and prove nothing. The reachable vector is the FALLBACK: `cp` follows a destination
# symlink, and the flag name is derived from public info (project path + session id).
# So force the fallback with a failing `mv` on PATH, which is the only way to exercise
# that branch deterministically.
R17="$ROOT/wr"; mkdir -p "$R17/cfg" "$R17/victim" "$R17/bin"
printf '#!/bin/sh\nexit 1\n' > "$R17/bin/mv"; chmod +x "$R17/bin/mv"
P17="$ROOT/p17"; mkproj "$P17"; C17="$CPD/p17.md"; mkcp "$C17" "WRITE"
# Learn this project's real flag path, then re-run with a symlink sitting on it.
DEST17=$( (cd "$P17" && CLAUDE_CONFIG_DIR="$(winp "$R17/cfg")" CLAUDE_CODE_SESSION_ID=s17 \
           bash "$ARM" "$C17" 2>/dev/null) | sed -n 's/^ARM_FLAG -> //p')
echo "PRECIOUS" > "$R17/victim/dest.txt"
rm -f "$DEST17"; ln -s "$R17/victim/dest.txt" "$DEST17"
(cd "$P17" && PATH="$R17/bin:$PATH" CLAUDE_CONFIG_DIR="$(winp "$R17/cfg")" CLAUDE_CODE_SESSION_ID=s17 \
   bash "$ARM" "$C17" >/dev/null 2>&1)
eq "cp fallback does not write through a symlinked flag path" "PRECIOUS" \
   "$(cat "$R17/victim/dest.txt")"
eq "the flag path is a real file afterwards" "file" \
   "$(if [ -L "$DEST17" ]; then echo LINK; elif [ -f "$DEST17" ]; then echo file; else echo missing; fi)"
eq "the fallback still arms correctly" "WRITE" \
   "$(node -e 'const fs=require("fs");
      const a=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      console.log(fs.readFileSync(a.checkpoint,"utf8").match(/Working on: (\w+)/)[1])' "$DEST17" 2>/dev/null)"
# mktemp names are random, so the guarantee to assert is that none are left behind:
# a stranded temp would otherwise sit under a name the old *.json sweep never reaped.
eq "no temp file left behind" "0" \
   "$(n=0; for f in "$R17/cfg/context-cycle/armed.d"/.tmp.*; do [ -e "$f" ] && n=$((n+1)); done; echo "$n")"
fi

echo "=== 18. install.sh: idempotent, and never silently reverts a local edit ==="
# The installer is the one component with no coverage at all, and its bare `cp`
# over an installed file is exactly how a patched copy used to vanish without a
# trace. Installs into a throwaway config dir; the repo clone is present, so the
# curl branch is never taken and this stays offline.
I="$(winp "$ROOT/inst")"; mkdir -p "$ROOT/inst"
inst() { (CLAUDE_CONFIG_DIR="$I" bash "$REPO/install.sh" 2>&1); }
inst >/dev/null; eq "install exits 0" "0" "$?"
eq "skill installed"    "1" "$([ -f "$ROOT/inst/skills/context-cycle/SKILL.md" ] && echo 1 || echo 0)"
eq "arm.sh installed"   "1" "$([ -f "$ROOT/inst/skills/context-cycle/arm.sh" ] && echo 1 || echo 0)"
eq "hook installed"     "1" "$([ -f "$ROOT/inst/hooks/context-cycle-restore.mjs" ] && echo 1 || echo 0)"
eq "SessionStart hook wired into settings.json" "1" \
   "$(grep -c 'context-cycle-restore' "$ROOT/inst/settings.json" 2>/dev/null || echo 0)"
# A reinstall of unchanged files must not churn a backup for every file it touches.
OUT18B=$(inst)
eq "reinstall reports the hook already present" "1" \
   "$(printf '%s' "$OUT18B" | grep -c 'already present')"
eq "no .bak churn when nothing differs" "0" \
   "$(ls -1 "$ROOT/inst/skills/context-cycle"/*.bak "$ROOT/inst/hooks"/*.bak 2>/dev/null | count)"
# The reported bug: a locally patched install is overwritten with no diff, no
# prompt and no backup. It must still be overwritten — but recoverably.
printf '\n# LOCAL PATCH\n' >> "$ROOT/inst/skills/context-cycle/arm.sh"
OUT18C=$(inst)
eq "local edit is backed up"     "1" "$([ -f "$ROOT/inst/skills/context-cycle/arm.sh.bak" ] && echo 1 || echo 0)"
eq "backup holds the local edit" "1" "$(grep -c 'LOCAL PATCH' "$ROOT/inst/skills/context-cycle/arm.sh.bak")"
eq "destination is the shipped version" "0" "$(grep -c 'LOCAL PATCH' "$ROOT/inst/skills/context-cycle/arm.sh")"
eq "destination matches the repo byte for byte" "same" \
   "$(cmp -s "$REPO/context-cycle/arm.sh" "$ROOT/inst/skills/context-cycle/arm.sh" && echo same || echo DIFFERS)"
eq "the overwrite is announced, not silent" "1" \
   "$(printf '%s' "$OUT18C" | grep -c 'arm.sh.bak')"
# Only the modified file gets a backup — an untouched sibling must stay clean.
eq "untouched sibling not backed up" "0" \
   "$([ -f "$ROOT/inst/skills/context-cycle/SKILL.md.bak" ] && echo 1 || echo 0)"
# A symlink at a destination must stop the install dead. `cp` resolves it in BOTH
# directions: the backup copies the link TARGET's contents out to a predictable
# .bak path (an arbitrary-file-read the bare-cp version did not have), and the
# install writes the shipped file through the link into that target.
if [ "$CAN_SYMLINK" = 1 ]; then
  printf 'SECRET-KEY-MATERIAL\n' > "$ROOT/inst-secret"
  rm -f "$ROOT/inst/skills/context-cycle/SKILL.md"
  ln -s "$ROOT/inst-secret" "$ROOT/inst/skills/context-cycle/SKILL.md"
  eq "install refuses a symlinked destination -> rc 1" "1" "$( (inst >/dev/null 2>&1); echo $? )"
  eq "link target never read out into a .bak" "0" \
     "$([ -e "$ROOT/inst/skills/context-cycle/SKILL.md.bak" ] && echo 1 || echo 0)"
  eq "link target never written through" "SECRET-KEY-MATERIAL" "$(cat "$ROOT/inst-secret")"
  rm -f "$ROOT/inst/skills/context-cycle/SKILL.md"
  inst >/dev/null 2>&1   # restore a clean install for the cases below

  # The .bak name is the same primitive one suffix over, and worse: `cp` follows a
  # link at its DESTINATION too, so a link pre-placed at the (entirely predictable)
  # .bak path makes the backup step write $dest's contents into it. This branch
  # fires on any upgrade where the installed file differs — not a rare edge case.
  printf 'SECRET-KEY-MATERIAL\n' > "$ROOT/inst-secret"
  printf '\n# LOCAL PATCH\n' >> "$ROOT/inst/skills/context-cycle/SKILL.md"   # force the backup branch
  ln -s "$ROOT/inst-secret" "$ROOT/inst/skills/context-cycle/SKILL.md.bak"
  eq "install refuses a symlinked .bak -> rc 1" "1" "$( (inst >/dev/null 2>&1); echo $? )"
  eq "nothing written through the .bak link" "SECRET-KEY-MATERIAL" "$(cat "$ROOT/inst-secret")"
  eq "the local edit is still there, not clobbered" "1" \
     "$(grep -c 'LOCAL PATCH' "$ROOT/inst/skills/context-cycle/SKILL.md")"
  rm -f "$ROOT/inst/skills/context-cycle/SKILL.md.bak"

  # settings.json.bak is the same hazard in the node block: copyFileSync follows a
  # symlinked destination exactly as cp does.
  ln -s "$ROOT/inst-secret" "$ROOT/inst/settings.json.bak"
  inst >/dev/null 2>&1
  eq "settings backup never written through a link" "SECRET-KEY-MATERIAL" "$(cat "$ROOT/inst-secret")"
  rm -f "$ROOT/inst/settings.json.bak"

  # A leaf check cannot see a link on the path LEADING to the file: `mkdir -p`
  # resolves a symlinked directory and succeeds, after which every [ -L ] on a
  # file inside it is false and the shipped files land in the link's target.
  J="$(winp "$ROOT/inst2")"; mkdir -p "$ROOT/inst2/skills" "$ROOT/decoy"
  ln -s "$ROOT/decoy" "$ROOT/inst2/skills/context-cycle"
  eq "install refuses a symlinked skill DIRECTORY -> rc 1" "1" \
     "$( (CLAUDE_CONFIG_DIR="$J" bash "$REPO/install.sh" >/dev/null 2>&1); echo $? )"
  eq "nothing installed into the link's target" "0" \
     "$(ls -1 "$ROOT/decoy" | count)"
else
  skip "group 18 symlinked-destination refusal" "this shell/filesystem does not create real symlinks"
fi

echo "=== 19. Same project, two path forms: the arm must still match ==="
# arm.cwd comes from `git rev-parse --show-toplevel` (PHYSICAL path); the payload
# cwd is whatever the session was launched in (possibly LOGICAL). They name the
# same directory and must match. This is not hypothetical: on macOS a repo under
# /var or /tmp is /private/... to git and /... to the shell, and in Git Bash the
# same directory can be an 8.3 short name on one side and the long name on the
# other. Both platforms failed EVERY restore assertion in CI before this was
# fixed, while Linux passed — the two forms happen to be identical there. A
# symlinked path reproduces the same divergence on any platform that has links.
if [ "$CAN_SYMLINK" = 1 ]; then
  P19="$ROOT/p19"; mkproj "$P19"
  ln -s "$P19" "$ROOT/p19-link"
  C19="$CPD/p19.md"; mkcp "$C19" "TWOFORMS"
  # Arm through the link: git reports the physical path, so arm.cwd is $ROOT/p19.
  (cd "$ROOT/p19-link" && CLAUDE_CODE_SESSION_ID=ff19-1919 bash "$ARM" "$C19" >/dev/null 2>&1)
  eq "clear at the physical path restores" \
     '✓ Restored: "TWOFORMS" · next: finish TWOFORMS (testbr)' "$(clear_in "$P19")"
  # And the reverse: armed at the physical path, cleared through the link.
  mkcp "$C19" "TWOFORMS"
  (cd "$P19" && CLAUDE_CODE_SESSION_ID=ff19-2929 bash "$ARM" "$C19" >/dev/null 2>&1)
  eq "clear at the logical path restores" \
     '✓ Restored: "TWOFORMS" · next: finish TWOFORMS (testbr)' "$(clear_in "$ROOT/p19-link")"
  eq "no arm left over" "0" "$(arms)"
  # Canonicalizing must not widen scope: an unrelated project still gets nothing.
  P19B="$ROOT/p19b"; mkproj "$P19B"
  (cd "$P19" && CLAUDE_CODE_SESSION_ID=ff19-3939 bash "$ARM" "$C19" >/dev/null 2>&1)
  eq "an unrelated project still does not match" "" "$(clear_in "$P19B")"
  eq "and that arm is still armed" "1" "$(arms)"
  rm -f "$ARMD"/*.json 2>/dev/null || true

  # The widening the two assertions above do NOT test, and the one that matters:
  # p19b and p19 are unrelated plain directories, so they never had any route to
  # each other. The route canonicalization opens is a symlink INSIDE one repo that
  # points at another. Without the raw-enclosing-repo check this restored p19's
  # checkpoint into a session whose cwd was inside p19b — reproduced, and it is the
  # only assertion here that fails against the un-narrowed canonicalization.
  mkdir -p "$P19B/vendor"
  ln -s "$P19" "$P19B/vendor/link"
  mkcp "$C19" "TWOFORMS"
  (cd "$P19" && CLAUDE_CODE_SESSION_ID=ff19-4949 bash "$ARM" "$C19" >/dev/null 2>&1)
  eq "a link inside another repo does not reach its arm" "" "$(clear_in "$P19B/vendor/link")"
  eq "and that arm survives the attempt" "1" "$(arms)"
  # Depth must not buy a bypass. The guard walks the raw path up looking for the repo
  # the link was planted in; if that walk gives up early, "ran out of budget" is
  # indistinguishable from "no repo above" and the caller allows it. A 64-iteration
  # version of this walk restored at depth 70 and blocked at 63 — burying the link
  # deep enough was the whole attack. Nesting directories inside a repo costs an
  # attacker nothing, so assert well past any plausible cap.
  D19="$P19B/deep"; i=0
  while [ "$i" -lt 80 ]; do D19="$D19/d"; i=$((i + 1)); done
  mkdir -p "$D19"; ln -s "$P19" "$D19/lnk"
  mkcp "$C19" "TWOFORMS"
  rm -f "$ARMD"/*.json 2>/dev/null || true   # the arm above survived; start from one
  (cd "$P19" && CLAUDE_CODE_SESSION_ID=ff19-5959 bash "$ARM" "$C19" >/dev/null 2>&1)
  eq "depth does not buy a bypass" "" "$(clear_in "$D19/lnk")"
  eq "and that arm survives it too" "1" "$(arms)"
  # ...while the same shape with no repo above the link — the macOS /var and Git Bash
  # short-name cases, and a plain ~/dev symlink — must still restore. This is the
  # line the check draws, so pin both sides of it.
  eq "but a link with no repo above it still restores" \
     '✓ Restored: "TWOFORMS" · next: finish TWOFORMS (testbr)' "$(clear_in "$ROOT/p19-link")"
  rm -f "$ARMD"/*.json 2>/dev/null || true
  # A backslash is an ordinary filename character on POSIX, so collapsing it to '/'
  # splits one directory name into two: the walk then stats `.git` under paths that
  # do not exist, finds no repo above the link, and the caller reads that as "benign
  # alias, allow". Naming the attacking repo `evil\repo` is the entire exploit, and
  # it restored until the collapse was gated on win32.
  if [ "$CAN_BACKSLASH_NAME" = 1 ]; then
    BSR="$ROOT/bs\\repo"; mkproj "$BSR"
    ln -s "$P19" "$BSR/link"
    mkcp "$C19" "TWOFORMS"
    (cd "$P19" && CLAUDE_CODE_SESSION_ID=ff19-6969 bash "$ARM" "$C19" >/dev/null 2>&1)
    eq "a backslash in the repo name does not hide it from the walk" "" "$(clear_in "$BSR/link")"
    eq "and that arm survives that too" "1" "$(arms)"
    rm -f "$ARMD"/*.json 2>/dev/null || true
  else
    skip "group 19 backslash-in-repo-name bypass" "this filesystem cannot hold a backslash in a name"
  fi
else
  skip "group 19 two-path-form scope matching" "this shell/filesystem does not create real symlinks"
fi

echo "=== 19b. A project nested inside another repo reaches its own arm ==="
# The aliasing guard asks what repository the RAW path belongs to. It used to demand
# that repository BE the armed project, which is false for every nested one: a linked
# worktree, a submodule, or any repo checked out inside another has the OUTER repo
# above it as written. So wherever the clearing cwd's raw and canonical forms differ —
# a symlink anywhere in the prefix, macOS /var, a Windows 8.3 short name — the outer
# repo was found, judged "not the armed project", and the arm refused. Silently: the
# clear looked like any other. Found on the macOS and Windows CI runners, where the
# temp path diverges on its own; reproduced on Linux with a symlink, which is what this
# group uses so it asserts on every platform rather than gating itself off.
#
# Six of these thirteen fail against the pre-change hook. The two boundary pairs — the
# outer repo, and a link that leaves its repo — pass either way by design: they are not
# evidence of the fix, they are what stops it from having loosened too far. The last
# three are aimed at a different variant entirely; see the comment above them.
if [ "$CAN_SYMLINK" = 1 ]; then
  N="$ROOT/n19"; mkdir -p "$N"; ln -s "$N" "$ROOT/n19-link"; NL="$ROOT/n19-link"
  mkproj "$N/main"; CN="$CPD/n19.md"

  # A submodule-shaped repo checked out inside another repo.
  mkproj "$N/main/sub"
  mkcp "$CN" "NESTED-SUB"
  (cd "$NL/main/sub" && CLAUDE_CODE_SESSION_ID=ff19-b101 bash "$ARM" "$CN" >/dev/null 2>&1)
  eq "a nested repo restores through a symlinked prefix" \
     '✓ Restored: "NESTED-SUB" · next: finish NESTED-SUB (testbr)' "$(clear_in "$NL/main/sub")"
  eq "...and its arm is consumed" "0" "$(arms)"

  # A linked worktree inside its own main repo. Written by hand for the same reason
  # group 8e does it: the gitdir the `.git` FILE points at is a fixture, not a real one.
  mkdir -p "$N/main/wt"; printf 'gitdir: %s/main/.git/worktrees/wt\n' "$N" > "$N/main/wt/.git"
  mkcp "$CN" "NESTED-WT"
  rm -f "$ARMD"/*.json
  cat > "$ARMD/bbbb1919-wt.json" <<EOF
{ "checkpoint": "$(winp "$CN")", "branch": "feat/elsewhere", "cwd": "$(winp "$N/main/wt")", "armed_at": $(date +%s) }
EOF
  eq "a linked worktree restores through a symlinked prefix" \
     '✓ Restored: "NESTED-WT" · next: finish NESTED-WT (feat/elsewhere)' "$(clear_in "$NL/main/wt")"
  eq "...and that arm is consumed" "0" "$(arms)"

  # Boundary, and it must not move: the OUTER repo is still a different project.
  mkcp "$CN" "NESTED-SUB"
  (cd "$NL/main/sub" && CLAUDE_CODE_SESSION_ID=ff19-b202 bash "$ARM" "$CN" >/dev/null 2>&1)
  eq "a clear in the outer repo does not take the nested arm" "" "$(clear_in "$NL/main")"
  eq "...and the nested arm survives it" "1" "$(arms)"
  rm -f "$ARMD"/*.json

  # The same relaxation closes a documented false negative: a git repo at an ANCESTOR
  # of the project (yadm, `git init ~`, a monorepo) plus the user's own shortcut into
  # it used to be refused, because the ancestor is not the armed project either.
  mkproj "$N/main/dev/proj"
  ln -s "$N/main/dev/proj" "$N/main/shortcut"
  mkcp "$CN" "ANCESTOR-REPO"
  (cd "$N/main/dev/proj" && CLAUDE_CODE_SESSION_ID=ff19-b303 bash "$ARM" "$CN" >/dev/null 2>&1)
  eq "a shortcut under a repo-shaped ancestor restores" \
     '✓ Restored: "ANCESTOR-REPO" · next: finish ANCESTOR-REPO (testbr)' "$(clear_in "$N/main/shortcut")"
  eq "...and that arm is consumed too" "0" "$(arms)"

  # Boundary, the one the guard exists for: a link that RESOLVES OUT of the repo it
  # sits in reaches nothing. This is the assertion that says the relaxation is
  # "inside the enclosing repo", not "an enclosing repo was found, so allow".
  P19X="$ROOT/p19x"; mkproj "$P19X"
  mkdir -p "$N/main/vendor"; ln -s "$P19X" "$N/main/vendor/out"
  CX="$CPD/p19x.md"; mkcp "$CX" "OUTSIDE"
  (cd "$P19X" && CLAUDE_CODE_SESSION_ID=ff19-b404 bash "$ARM" "$CX" >/dev/null 2>&1)
  eq "a link that leaves its repo still reaches no arm" "" "$(clear_in "$N/main/vendor/out")"
  eq "...and that arm survives the attempt" "1" "$(arms)"
  rm -f "$ARMD"/*.json

  # The relaxation must not widen the SIBLING gap that is still open in TODOS.md: a
  # /clear in a subdirectory of a repo nested BELOW the armed project matches the
  # parent's arm, because the check downstream stats `.git` in the leaf only. Asking
  # for containment alone made that gap reachable through a symlink as well, where the
  # old form refused — caught in review, reproduced both ways. The first pair fails
  # against the containment-only version this group was first written for, NOT against
  # main: it pins that this change stayed scope-neutral for that item rather than
  # quietly taking half of it.
  mkproj "$N/main/vendor/nested"; mkdir -p "$N/main/vendor/nested/src"
  ln -s "$N/main/vendor/nested" "$N/nested-link"
  mkcp "$CN" "PARENT"
  (cd "$N/main" && CLAUDE_CODE_SESSION_ID=ff19-b505 bash "$ARM" "$CN" >/dev/null 2>&1)
  eq "a link into a nested repo's subdir does not reach the parent's arm" \
     "" "$(clear_in "$N/nested-link/src")"
  eq "...and the parent's arm survives it" "1" "$(arms)"
  # The other half of that invariant, on a FRESH arm. Reusing the arm above would make
  # this fail whenever the symlinked clear wrongly consumed it — fallout from the line
  # before, not evidence about the direct route — so it would look like a third negative
  # control while testing nothing of its own. Re-armed, it passes against every variant
  # tried, which is the point: it is the over-refusal guard, and it fails only if the
  # condition added here ever starts eating the direct route too.
  rm -f "$ARMD"/*.json
  (cd "$N/main" && CLAUDE_CODE_SESSION_ID=ff19-b506 bash "$ARM" "$CN" >/dev/null 2>&1)
  eq "...while the direct route still matches it (the sibling gap, untouched)" \
     '✓ Restored: "PARENT" · next: finish PARENT (testbr)' "$(clear_in "$N/main/vendor/nested/src")"
  rm -f "$ARMD"/*.json
else
  skip "group 19b nested-project scope" "this shell/filesystem does not create real symlinks"
fi

echo "=== 20. Two projects differing only in case are two projects ==="
# norm() used to lowercase every path unconditionally, on the theory that the
# filesystem is case-insensitive — true on Windows, false on Linux and on a
# case-sensitive macOS volume. There it merged two unrelated repos into one, so an
# arm taken in Proj was consumed by a /clear in proj, with no symlink anywhere. It
# also disabled the aliasing guard in group 19: folding case made the raw and
# canonical forms compare equal, so the divergence branch never ran. Now gated on
# win32, which leaves Windows behaviour untouched.
if [ "$CASE_SENSITIVE" = 1 ]; then
  PU="$ROOT/Pcase"; PL="$ROOT/pcase"; mkproj "$PU"; mkproj "$PL"
  C20="$CPD/p20.md"; mkcp "$C20" "CASEFOLD"
  (cd "$PU" && CLAUDE_CODE_SESSION_ID=ff20-1010 bash "$ARM" "$C20" >/dev/null 2>&1)
  eq "an arm in Pcase is not consumed by a clear in pcase" "" "$(clear_in "$PL")"
  eq "and that arm is still armed" "1" "$(arms)"
  eq "while the project it was armed in still restores" \
     '✓ Restored: "CASEFOLD" · next: finish CASEFOLD (testbr)' "$(clear_in "$PU")"
  rm -f "$ARMD"/*.json 2>/dev/null || true
else
  skip "group 20 case-collision scope matching" "this filesystem treats Proj and proj as one directory"
fi

echo "=== 21. Scripts the README says to run as ./x are tracked executable ==="
# README's clone path is `./install.sh` and `./uninstall.sh`, and both shipped tracked
# 100644 -- so anyone following it got `Permission denied` at the first step. It
# survived to a release because the documented curl|bash path pipes into an
# interpreter and never needs the bit, and because a fresh `chmod +x` in a working
# copy makes it invisible locally: the mode lives in the INDEX, so that is what this
# asserts. arm.sh is deliberately NOT here -- SKILL.md invokes it as `bash arm.sh`, so
# 100644 is correct for it, and asserting otherwise would encode a rule the project
# does not follow.
if git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  for f in install.sh uninstall.sh; do
    eq "$f is tracked executable" "100755" \
       "$(git -C "$REPO" ls-files -s "$f" 2>/dev/null | awk '{print $1}')"
  done
else
  skip "group 21 (tracked exec bits)" "not a git work tree — running from an export, so index modes are unavailable"
fi

echo "=== 22. checkpoint is confined to the checkpoint directories ==="
# The arm flag used to be an arbitrary-file-READ primitive: `checkpoint` was read
# verbatim from any absolute path and injected into model context. Measured against
# that hook, not assumed: of the twenty assertions here, twelve fail because it
# restored what it should have refused and three because the arm did not survive to be
# recovered; three pass there for the wrong reason (they assert an arm count or an
# absent injection, which a hook that already consumed the flag satisfies vacuously)
# and two are positive controls that must pass on both. Do not upgrade that to "every
# assertion fails against the old hook" — an earlier version of this comment did, and
# it was wrong in both directions.
#
# What this group does NOT prove, and must not be read as proving: an attacker who
# can write the flag can usually write INTO an allowed root too, and a payload placed
# there is read exactly as before. The roots stop the arbitrary read, not the
# injection — see TODOS.md.
rm -f "$ARMD"/*.json
P22="$ROOT/p22"; mkproj "$P22"
OUTSIDE22="$ROOT/not-a-checkpoint-dir"; mkdir -p "$OUTSIDE22"
C22="$OUTSIDE22/secret.md"; mkcp "$C22" "STOLEN"
arm22() { (cd "$P22" && CLAUDE_CODE_SESSION_ID="$1" bash "$ARM" "$2" >/dev/null 2>&1); }

arm22 s22a "$C22"
eq "an out-of-root checkpoint is armed but not restored" "refused" "$(refused_in "$P22")"
# The refusal has to reach the USER. Silence here is the failure mode this whole
# project keeps finding: the /clear looks ordinary and the context never comes back.
REFUSE22=$(node -e 'process.stdout.write(JSON.stringify({source:"clear",cwd:process.argv[1]}))' \
   "$(winp "$P22")" | node "$HOOK")
eq "and the user is told why, with the escape hatch named" "1" \
   "$(case "$REFUSE22" in *"outside the known"*CONTEXT_CYCLE_CHECKPOINT_ROOTS*) echo 1;; *) echo 0;; esac)"
eq "the refused arm is NOT consumed" "1" "$(arms)"
eq "and nothing was injected into model context" "0" \
   "$(case "$REFUSE22" in *additionalContext*) echo 1;; *) echo 0;; esac)"
# Recoverability end-to-end: the same arm, still on disk, restores once the root is
# declared. This is why a refusal must not drop the flag — a mis-derived root would
# otherwise destroy a legitimate pending restore instead of merely delaying it.
eq "declaring the root recovers that very arm" \
   '✓ Restored: "STOLEN" · next: finish STOLEN (testbr)' \
   "$(CONTEXT_CYCLE_CHECKPOINT_ROOTS="$(winp "$OUTSIDE22")" clear_in "$P22")"
eq "...and only then is it consumed" "0" "$(arms)"

# Prefix boundary: a sibling directory whose name merely STARTS with the root's is
# not inside it. `startsWith(root)` without the separator would admit this.
SIB22="${CPD}-evil"; mkdir -p "$SIB22"; C22B="$SIB22/x.md"; mkcp "$C22B" "SIBLING"
arm22 s22b "$C22B"
eq "a sibling dir sharing the root's prefix is refused" "refused" "$(refused_in "$P22")"
rm -f "$ARMD"/*.json

# Traversal: spelled inside the root, lands outside it. canon() collapses the `..`
# when the path exists; normalize() covers it when it does not.
C22C="$CPD/../../escape.md"; mkcp "$C22C" "TRAVERSED"
arm22 s22c "$C22C"
eq "a ../ traversal out of the root is refused" "refused" "$(refused_in "$P22")"
rm -f "$ARMD"/*.json

# Relative paths are refused outright rather than resolved: the base would be the
# process cwd, which is not a trust anchor. Hand-written into the flag, because
# arm.sh absolutizes what it is given — and the file is placed where that cwd WILL
# find it, so the assertion exercises the refusal rather than the "checkpoint gone"
# path it would otherwise fall into and pass for the wrong reason.
mkcp "$P22/relnotes.md" "RELATIVE"
cat > "$ARMD/rel22.json" <<EOF
{ "checkpoint": "relnotes.md", "branch": "testbr", "cwd": "$(winp "$P22")", "armed_at": $(date +%s) }
EOF
REL22=$( cd "$P22" && node -e 'process.stdout.write(JSON.stringify({source:"clear",cwd:process.argv[1]}))' \
   "$(winp "$P22")" | node "$HOOK" )
eq "a relative checkpoint path is refused even when it resolves" "1" \
   "$(case "$REL22" in *"outside the known"*) echo 1;; *) echo 0;; esac)"
eq "...and it stays armed like any other refusal" "1" "$(arms)"
rm -f "$ARMD"/*.json "$P22/relnotes.md"

# The gstack root, derived from GSTACK_HOME exactly as gstack's own bin/gstack-paths
# does — and NOT by executing it. SKILL.md writes $GSTACK_STATE_ROOT/projects/$SLUG/
# checkpoints, so `projects` is the root the hook has to accept.
G22="$ROOT/gstack-home"; mkdir -p "$G22/projects/p22/checkpoints"
C22G="$G22/projects/p22/checkpoints/g.md"; mkcp "$C22G" "GSTACK"
arm22 s22g "$C22G"
eq "a gstack checkpoint is refused without the env that derives its root" "refused" "$(refused_in "$P22")"
eq "...and restores with GSTACK_HOME set" \
   '✓ Restored: "GSTACK" · next: finish GSTACK (testbr)' \
   "$(GSTACK_HOME="$(winp "$G22")" clear_in "$P22")"

# CLAUDE_PLUGIN_DATA is only trusted when CLAUDE_PLUGIN_ROOT confirms gstack is the
# plugin in play — gstack's own guard, kept, because another plugin's data dir can
# reach the session env and would otherwise become a checkpoint root for free.
arm22 s22p "$C22G"
eq "CLAUDE_PLUGIN_DATA alone does not make a root" "refused" \
   "$(CLAUDE_PLUGIN_DATA="$(winp "$G22")" refused_in "$P22")"
eq "...but does when CLAUDE_PLUGIN_ROOT names gstack" \
   '✓ Restored: "GSTACK" · next: finish GSTACK (testbr)' \
   "$(CLAUDE_PLUGIN_DATA="$(winp "$G22")" CLAUDE_PLUGIN_ROOT="/x/plugins/gstack" clear_in "$P22")"
rm -f "$ARMD"/*.json

# A refused arm sorting FIRST must not hide a good one behind it: the good arm still
# restores, and the banner still carries the warning. Without the second half a
# planted flag is refused invisibly and the user sees an ordinary green banner.
C22OK="$CPD/p22-ok.md"; mkcp "$C22OK" "LEGIT"
arm22 s22x "$C22"; sleep 1; arm22 s22y "$C22OK"
BOTH22=$(clear_in "$P22")
eq "a refused arm does not block a good one behind it" "1" \
   "$(case "$BOTH22" in '✓ Restored: "LEGIT"'*) echo 1;; *) echo 0;; esac)"
eq "...and the successful banner still reports the refusal" "1" \
   "$(case "$BOTH22" in *"outside the known"*) echo 1;; *) echo 0;; esac)"
eq "the refused arm is still armed after that restore" "1" "$(arms)"
rm -f "$ARMD"/*.json

if [ "$CAN_SYMLINK" = 1 ]; then
  # A symlink sitting INSIDE an allowed root, pointing out of it. Canonicalizing the
  # candidate is what catches this; a check on the spelling alone would admit it, and
  # it is the shape an attacker gets for free once they can write into the root.
  ln -s "$C22" "$CPD/looks-legit.md"
  arm22 s22l "$CPD/looks-legit.md"
  eq "a symlink out of the root is refused" "refused" "$(refused_in "$P22")"
  rm -f "$CPD/looks-legit.md" "$ARMD"/*.json
  # The hook reads the RESOLVED path, not the string the flag gave it, so the same
  # link cannot be re-pointed out of the root between the check and the read. That
  # swap race has no deterministic test — it needs the swap to land inside a window
  # measured in microseconds — so this asserts the half that can be: resolving must
  # not cost a legitimate in-root link its restore. Passes against the pre-change
  # hook too, and is here as a regression guard rather than a discriminator.
  C22I="$CPD/inner-target.md"; mkcp "$C22I" "INNERLINK"
  ln -s "$C22I" "$CPD/inner-link.md"
  arm22 s22i "$CPD/inner-link.md"
  eq "a symlink inside the root pointing inside it still restores" \
     '✓ Restored: "INNERLINK" · next: finish INNERLINK (testbr)' "$(clear_in "$P22")"
  rm -f "$CPD/inner-link.md" "$C22I" "$ARMD"/*.json
  # The mirror image, which must keep working: the root ITSELF reached through a
  # link. Group 16 covers the config root; this covers a checkpoints dir that is a
  # link, which canonicalizing both sides is what makes agree.
  R22="$ROOT/cpstore"; mkdir -p "$R22"
  mv "$CPD" "$R22/real-checkpoints"; ln -s "$R22/real-checkpoints" "$CPD"
  C22S="$CPD/linked.md"; mkcp "$C22S" "LINKEDROOT"
  arm22 s22s "$C22S"
  eq "a symlinked checkpoints dir still restores" \
     '✓ Restored: "LINKEDROOT" · next: finish LINKEDROOT (testbr)' "$(clear_in "$P22")"
  rm -f "$CPD"; mv "$R22/real-checkpoints" "$CPD"
else
  skip "group 22 symlink half" "this shell/filesystem does not create real symlinks"
fi
rm -f "$ARMD"/*.json

echo "=== 23. Arms are ordered by write time, not by the flag's own armed_at ==="
# `armed_at` is written by whoever wrote the flag. The candidate sort used to read it,
# so a planted flag claiming a plausible earlier time sorted ahead of every legitimate
# arm in its project and won every /clear outright, rather than having to win a race.
# Ordering now runs on the inode's change time, which no POSIX call can set.
#
# The planted flags below are what an attacker with write access to armed.d would
# actually write: well-formed, `cwd` matching the project, and the checkpoint inside an
# allowed root so group 22's confinement passes them. `armed_at` is a minute ago, not 0
# or 1 — the shape check in isLive() rejects those, and asserting against a forgery the
# shape check already stops would test nothing.
#
# The filename sorts AFTER a hash-named real arm, so the path tiebreak favours the
# legitimate flag. That does not soften the discriminators: against the pre-change hook
# the two armed_at values differ by a minute, so the comparator returns on the first
# term and the tiebreak is never consulted.
rm -f "$ARMD"/*.json
P23="$ROOT/p23"; mkproj "$P23"
C23L="$CPD/p23-legit.md";   mkcp "$C23L" "LEGIT"
C23M="$CPD/p23-legit2.md";  mkcp "$C23M" "LEGIT2"
C23P="$CPD/p23-planted.md"; mkcp "$C23P" "PLANTED"
arm23()   { (cd "$P23" && CLAUDE_CODE_SESSION_ID="$1" bash "$ARM" "$2" >/dev/null 2>&1); }
# plant23 <slot> <checkpoint> <armed_at>
plant23() { cat > "$ARMD/zz-planted-$1.json" <<EOF
{ "checkpoint": "$(winp "$2")", "branch": "testbr", "cwd": "$(winp "$P23")", "armed_at": $3 }
EOF
}

# The attack: arm legitimately, then plant a flag backdated to before that arm.
arm23 s23a "$C23L"
sleep 1
plant23 a "$C23P" "$(( $(date +%s) - 60 ))"
eq "planted flag and real arm coexist" "2" "$(arms)"
eq "the real arm restores first, not the backdated one" \
   '✓ Restored: "LEGIT" · next: finish LEGIT (testbr)' "$(clear_in "$P23")"
# Deliberately asserted rather than left implicit: losing the sort costs an attacker
# one cycle and nothing more. The flag is not consumed, not swept, and is a candidate
# again at the very next /clear. Ordering is not a defence on its own.
eq "the planted flag is still there and fires on the next clear" \
   '✓ Restored: "PLANTED" · next: finish PLANTED (testbr)' "$(clear_in "$P23")"
eq "both flags are consumed after two clears" "0" "$(arms)"

# The limit, pinned so it cannot be mistaken for coverage: this orders by when a flag
# was written, it does not authenticate who wrote it. A flag planted BEFORE a real arm
# genuinely is older and still sorts first. Passes against the pre-change hook too.
rm -f "$ARMD"/*.json
plant23 b "$C23P" "$(( $(date +%s) - 60 ))"
sleep 1
arm23 s23b "$C23L"
eq "a flag planted BEFORE the real arm still wins — write order, not provenance" \
   '✓ Restored: "PLANTED" · next: finish PLANTED (testbr)' "$(clear_in "$P23")"
rm -f "$ARMD"/*.json

# armed_at is ignored, not clamped: a flag cannot push itself LATER either. Written
# first with a stamp a day in the future, it still sorts first. Against the pre-change
# hook the future stamp sent it to the back and the real arm restored instead, so this
# is a discriminator in the opposite direction from the one above.
plant23 c "$C23P" "$(( $(date +%s) + 86400 ))"
sleep 1
arm23 s23c "$C23L"
eq "a future-stamped flag written first is not sorted to the back" \
   '✓ Restored: "PLANTED" · next: finish PLANTED (testbr)' "$(clear_in "$P23")"
rm -f "$ARMD"/*.json

# Positive control: the ordering the sort exists for still holds. Two sessions arming
# in one project, cleared in the order they armed, each get their own checkpoint back.
# Passes on both hooks — it is here so a change that fixed the forgery by breaking
# legitimate pairing cannot go unnoticed.
arm23 s23d "$C23L"
sleep 1
arm23 s23e "$C23M"
eq "two real arms: first clear gets the older" \
   '✓ Restored: "LEGIT" · next: finish LEGIT (testbr)' "$(clear_in "$P23")"
eq "two real arms: second clear gets the newer" \
   '✓ Restored: "LEGIT2" · next: finish LEGIT2 (testbr)' "$(clear_in "$P23")"
rm -f "$ARMD"/*.json

echo "=== 24. An armed.d entry that is not a regular file is never read ==="
# The bypass group 23's ordering had on its own. Both readFileSync (content) and
# statSync (the sort key) FOLLOW a symlink and report the TARGET, so a link grafts a
# fresh directory entry onto an inode the attacker last touched whenever they liked —
# no race, no backdating, and the ctime sort reads the staged file's untouched time.
# Reproduced against the version of the hook that had the ctime sort but not the
# refusal: a flag staged outside armed.d, then linked in two seconds AFTER a legitimate
# arm, still sorted first and restored the planted checkpoint.
rm -f "$ARMD"/*.json
# plant_file <path> <checkpoint> — a well-formed flag for P23, written somewhere the
# hook does not look. Its ctime is set here and never moves again.
plant_file() { cat > "$1" <<EOF
{ "checkpoint": "$(winp "$2")", "branch": "testbr", "cwd": "$(winp "$P23")", "armed_at": $(date +%s) }
EOF
}
if [ "$CAN_SYMLINK" -eq 1 ]; then
  S24="$ROOT/staged-24.json"; plant_file "$S24" "$C23P"
  sleep 1
  arm23 s24a "$C23L"
  sleep 1
  ln -s "$S24" "$ARMD/zz-linked.json"
  B24="$(clear_in "$P23")"
  eq "a symlinked entry does not win the sort" \
     '✓ Restored: "LEGIT" · next: finish LEGIT (testbr)' "$(restored_line "$B24")"
  eq "and the skip is reported, not silent" "warned" "$(odd_note "$B24")"
  # Losing one sort is not the property being claimed — a symlink must be inert, not
  # merely later. The next clear has no legitimate arm left for it to lose to.
  eq "the link is still on disk (the hook does not delete what it won't read)" \
     "present" "$([ -L "$ARMD/zz-linked.json" ] && echo present || echo absent)"
  B24B="$(clear_in "$P23")"
  eq "with nothing to lose to, it still restores nothing" "" "$(restored_line "$B24B")"
  eq "and says so again rather than clearing into silence" "warned" "$(odd_note "$B24B")"
  rm -f "$ARMD"/*.json "$S24"
else
  skip "24 (symlinked armed.d entry)" "this filesystem cannot create symlinks"
fi

# A hardlink is deliberately NOT refused, and that is a claim needing evidence rather
# than reasoning: it is a regular file, so scanArms() admits it, and the ordering
# guarantee has to survive on its own. link() is a metadata write and moves the target
# inode's ctime FORWARD, so a hardlink planted after a real arm sorts after it. If that
# were ever false, this group goes red instead of the refusal quietly under-covering.
if [ "$CAN_HARDLINK" -eq 1 ]; then
  H24="$ROOT/staged-24-hard.json"; plant_file "$H24" "$C23P"
  sleep 1
  arm23 s24b "$C23L"
  sleep 1
  if ln "$H24" "$ARMD/zz-hard.json" 2>/dev/null; then
    eq "a hardlinked flag is accepted but link() moved its ctime forward" \
       '✓ Restored: "LEGIT" · next: finish LEGIT (testbr)' "$(restored_line "$(clear_in "$P23")")"
  else
    skip "24 (hardlinked armed.d entry)" "ln refused to link into the state dir"
  fi
  rm -f "$ARMD"/*.json "$H24"
else
  skip "24 (hardlinked armed.d entry)" "this filesystem cannot create hardlinks"
fi

# A FIFO is the other thing that can sit on a flag path, and it fails differently:
# O_NOFOLLOW says nothing about one, and opening the read end with no writer BLOCKS.
# The lstat in scanArms() is what keeps a statically planted one from ever reaching
# the open, so this asserts the outer layer holds AND that the hook returns at all —
# a regression that dropped the lstat and relied on O_NOFOLLOW alone would hang
# session startup, not merely mis-sort. Wrapped in `timeout` so that regression shows
# up as one red assertion instead of a suite that never finishes.
# Say the limit rather than let the group's name imply otherwise: these two are NOT a
# discriminator for the O_NONBLOCK that ships with them. Reverting that constant alone
# leaves both green, because from here the open is never reached — checked by running
# the suite against a stripped hook, not assumed. The flag is only reachable through
# the scan→open race, which the suite cannot win; see TODOS.md.
if command -v mkfifo >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
  rm -f "$ARMD"/*.json
  arm23 s24c "$C23L"
  if mkfifo "$ARMD/zz-fifo.json" 2>/dev/null; then
    B24F="$(timeout 20 node -e 'process.stdout.write(JSON.stringify({source:"clear",cwd:process.argv[1],session_id:"post-clear-new-uuid"}))' "$(winp "$P23")" | timeout 20 node "$HOOK" | jsonf banner)"
    eq "a FIFO on a flag path does not hang the hook, and the arm still restores" \
       '✓ Restored: "LEGIT" · next: finish LEGIT (testbr)' "$(restored_line "$B24F")"
    eq "and the FIFO is reported like any other non-regular entry" "warned" "$(odd_note "$B24F")"
    rm -f "$ARMD/zz-fifo.json"
  else
    skip "24 (FIFO on a flag path)" "mkfifo refused inside the state dir"
  fi
  rm -f "$ARMD"/*.json
else
  skip "24 (FIFO on a flag path)" "mkfifo or timeout is unavailable"
fi

echo
printf '=== %d passed, %d failed, %d skipped ===\n' "$PASS" "$FAIL" "$SKIP"
[ "$SKIP" -eq 0 ] || printf 'skipped on this platform (%s):%s\n' "$(uname -s 2>/dev/null || echo unknown)" "$SKIPPED"
[ "$FAIL" -eq 0 ]
