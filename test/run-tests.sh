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

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

# A skipped group is reported by name and re-listed in the summary. A suite that
# quietly drops a third of itself on one platform reads as full coverage.
SKIP=0; SKIPPED=""
skip() { SKIP=$((SKIP+1)); SKIPPED="$SKIPPED
  - $1 — $2"; printf '  SKIP %s\n       reason: %s\n' "$1" "$2"; }

# Age a file past the hook's 3600s TTL, creating it first if absent — i.e. exactly
# what `touch -d '3 hours ago'` did. That form is GNU-only (BSD/macOS touch has no
# -d like it), and node is already a hard requirement of the hook under test, so
# this adds no new dependency.
age() { [ -e "$1" ] || : > "$1"; node -e 'const t = Date.now()/1000 - 10800; require("fs").utimesSync(process.argv[1], t, t)' "$1"; }

# Count lines on stdin. BSD `wc -l` pads its output with leading spaces and GNU does
# not, so a bare `$(... | wc -l)` compared against a literal "1" passes on Linux and
# fails on macOS with the gloriously unhelpful `expected: 1 / actual:          1`.
# Two call sites had `tr -d ' '` and four did not; every count goes through here now
# so the next one cannot be added without it.
count() { wc -l | tr -d ' '; }

# Capability probes for the hostile-state groups. Git Bash without
# MSYS=winsymlinks:nativestrict turns `ln -s` into a plain copy, and NTFS rejects
# '"' and control bytes in filenames outright.
CAN_SYMLINK=0
ln -s "$ROOT" "$ROOT/.symprobe" 2>/dev/null && [ -L "$ROOT/.symprobe" ] && CAN_SYMLINK=1
rm -f "$ROOT/.symprobe" 2>/dev/null
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
# control bytes, and a volume could accept one set and not the other.
CAN_BACKSLASH_NAME=0
mkdir -p "$ROOT/.bs\\probe" 2>/dev/null
[ -d "$ROOT/.bs\\probe" ] && CAN_BACKSLASH_NAME=1
rm -rf "$ROOT/.bs\\probe" 2>/dev/null

# Pull one field out of the hook's JSON stdout. node, not python — node is
# already a hard requirement of the hook itself, so the suite adds no new dep.
jsonf() { node -e '
  let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
    const d = JSON.parse(s), ac = d.hookSpecificOutput.additionalContext;
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
mkcp() { printf '## Working on: %s\n\n### Remaining Work\n1. finish %s\n' "$2" "$2" > "$1"; }
mkproj() { mkdir -p "$1"; git -C "$1" init -q -b testbr 2>/dev/null; git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null; }
arms() { ls -1 "$ARMD" 2>/dev/null | grep -c '\.json$' || true; }

echo "=== 1. THE REPORTED BUG: two sessions, same project, interleaved ==="
P="$ROOT/p1"; mkproj "$P"
A="$ROOT/p1-A.md"; B="$ROOT/p1-B.md"; mkcp "$A" "ALPHA"; mkcp "$B" "BRAVO"
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
CA="$ROOT/p2a.md"; CB="$ROOT/p2b.md"; mkcp "$CA" "PROJ-A"; mkcp "$CB" "PROJ-B"
(cd "$PA" && CLAUDE_CODE_SESSION_ID=s-a bash "$ARM" "$CA" >/dev/null 2>&1)
(cd "$PB" && CLAUDE_CODE_SESSION_ID=s-b bash "$ARM" "$CB" >/dev/null 2>&1)
eq "two project arms coexist" "2" "$(arms)"
eq "clear in A gets PROJ-A" '✓ Restored: "PROJ-A" · next: finish PROJ-A (testbr)' "$(clear_in "$PA")"
eq "B's arm survives A's clear" "1" "$(arms)"
eq "clear in B gets PROJ-B" '✓ Restored: "PROJ-B" · next: finish PROJ-B (testbr)' "$(clear_in "$PB")"

echo "=== 3. Single-session baseline (must not break) ==="
P3="$ROOT/p3"; mkproj "$P3"; C3="$ROOT/p3.md"; mkcp "$C3" "SOLO"
(cd "$P3" && CLAUDE_CODE_SESSION_ID=solo-1 bash "$ARM" "$C3" >/dev/null 2>&1)
eq "solo restore fires"   '✓ Restored: "SOLO" · next: finish SOLO (testbr)' "$(clear_in "$P3")"
eq "one-shot: 2nd is no-op" "" "$(clear_in "$P3")"

echo "=== 4. Re-arm in the SAME session supersedes (newest wins, no accumulation) ==="
P4="$ROOT/p4"; mkproj "$P4"; O="$ROOT/p4-old.md"; N="$ROOT/p4-new.md"
mkcp "$O" "STALE-DRAFT"; mkcp "$N" "REDONE"
(cd "$P4" && CLAUDE_CODE_SESSION_ID=same-sess bash "$ARM" "$O" >/dev/null 2>&1)
sleep 1
(cd "$P4" && CLAUDE_CODE_SESSION_ID=same-sess bash "$ARM" "$N" >/dev/null 2>&1)
eq "still exactly one arm" "1" "$(arms)"
eq "newest checkpoint wins" '✓ Restored: "REDONE" · next: finish REDONE (testbr)' "$(clear_in "$P4")"

echo "=== 5. Legacy single-slot armed.json (session mid-cycle when this lands) ==="
P5="$ROOT/p5"; mkproj "$P5"; C5="$ROOT/p5.md"; mkcp "$C5" "LEGACY"
cat > "$CLAUDE_CONFIG_DIR/context-cycle/armed.json" <<EOF
{ "checkpoint": "$(winp "$C5")", "branch": "main", "cwd": "$(winp "$P5")", "armed_at": $(date +%s) }
EOF
eq "legacy arm is consumed" '✓ Restored: "LEGACY" · next: finish LEGACY (main)' "$(clear_in "$P5")"
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
P7="$ROOT/p7"; mkproj "$P7"; C7="$ROOT/p7.md"; mkcp "$C7" "GOOD"
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
: > "$ROOT/empty.md"
eq "empty checkpoint -> rc 1"   "1" "$(rc "$ROOT/empty.md")"
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

echo "=== 8. TTL: a stale arm is swept, never restored ==="
P8="$ROOT/p8"; mkproj "$P8"; C8="$ROOT/p8.md"; mkcp "$C8" "STALE"
mkdir -p "$ARMD"
cat > "$ARMD/deadbeef1234-oldsess.json" <<EOF
{ "checkpoint": "$(winp "$C8")", "branch": "", "cwd": "$(winp "$P8")", "armed_at": $(( $(date +%s) - 7200 )) }
EOF
eq "stale arm does not restore" "" "$(clear_in "$P8")"
eq "stale arm swept from disk"  "0" "$(arms)"

echo "=== 9. Non-clear session starts never consume the arm ==="
P9="$ROOT/p9"; mkproj "$P9"; C9="$ROOT/p9.md"; mkcp "$C9" "KEEP"
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
C11="$ROOT/p11.md"; mkcp "$C11" "MONO"
(cd "$P11" && CLAUDE_CODE_SESSION_ID=s11 bash "$ARM" "$C11" >/dev/null 2>&1)
eq "clear in a nested REPO does not fire" "" "$(clear_in "$P11/vendor/lib")"
eq "arm survives the nested-repo clear"   "1" "$(arms)"
eq "clear in a plain subdir does fire" '✓ Restored: "MONO" · next: finish MONO (testbr)' "$(clear_in "$P11/frontend")"
# unrelated project must never match
C11b="$ROOT/p11b.md"; mkcp "$C11b" "MONO2"
(cd "$P11" && CLAUDE_CODE_SESSION_ID=s11b bash "$ARM" "$C11b" >/dev/null 2>&1)
eq "clear in an unrelated dir does not fire" "" "$(clear_in "$ROOT/p2a")"
eq "arm survives that too" "1" "$(arms)"
rm -f "$ARMD"/*.json

echo "=== 12. Vanished checkpoint: skip to the next arm, never delete a checkpoint ==="
P12="$ROOT/p12"; mkproj "$P12"
G="$ROOT/p12-gone.md"; K="$ROOT/p12-kept.md"; mkcp "$G" "GONE"; mkcp "$K" "KEPT"
(cd "$P12" && CLAUDE_CODE_SESSION_ID=s12a bash "$ARM" "$G" >/dev/null 2>&1)
sleep 1
(cd "$P12" && CLAUDE_CODE_SESSION_ID=s12b bash "$ARM" "$K" >/dev/null 2>&1)
rm -f "$G"                                   # user moved/deleted it out of band
eq "falls through to the live arm" '✓ Restored: "KEPT" · next: finish KEPT (testbr)' "$(clear_in "$P12")"
eq "both dead+used arms cleared" "0" "$(arms)"
BEFORE=$(ls -1 "$ROOT"/*.md | count)
(cd "$P12" && CLAUDE_CODE_SESSION_ID=s12c bash "$ARM" "$K" >/dev/null 2>&1)
clear_in "$P12" >/dev/null
eq "checkpoint files never deleted by a restore" "$BEFORE" "$(ls -1 "$ROOT"/*.md | count)"

echo "=== 13. Payload shape: full multi-KB checkpoint survives writeSync ==="
P13="$ROOT/p13"; mkproj "$P13"; C13="$ROOT/p13.md"
{ printf '## Working on: BIG\n\n### Remaining Work\n1. finish BIG\n\n'
  for i in $(seq 1 400); do printf 'padding line %d with some prose to make this multi-KB\n' "$i"; done; } > "$C13"
(cd "$P13" && CLAUDE_CODE_SESSION_ID=s13 bash "$ARM" "$C13" >/dev/null 2>&1)
RES=$(printf '{"source":"clear","cwd":"%s"}' "$(winp "$P13")" | node "$HOOK" | jsonf shape)
eq "valid JSON, complete, truncation-noted" "SessionStart true true true" "$RES"
eq "checkpoint size on disk" "1" "$([ "$(wc -c < "$C13")" -gt 9000 ] && echo 1 || echo 0)"

echo "=== 14. Hostile state dir: symlinked armed.d, control chars in paths ==="
rm -f "$ARMD"/*.json
P14="$ROOT/p14"; mkproj "$P14"; C14="$ROOT/p14.md"; mkcp "$C14" "SYM"
if [ "$CAN_SYMLINK" = 1 ]; then
# A symlinked armed.d must not become a delete-anything primitive: readdirSync +
# unlinkSync resolve through it, so the hook would reap *.json from the target.
# The target file must be past the TTL: sweep() only reaps an unparseable flag
# once it is stale, so a fresh file would survive even WITHOUT the guard and the
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
# no error) until the TTL reaps it. arm.sh must reject it loudly instead.
NLCP="$ROOT/$(printf 'we\vird').md"; mkcp "$NLCP" "CTRL" 2>/dev/null
eq "control char in checkpoint path -> rc 1" "1" \
   "$( (cd "$P14" && bash "$ARM" "$NLCP" >/dev/null 2>&1); echo $? )"
eq "and nothing was armed" "0" "$(arms)"
# esc() backstop: whatever reaches the flag, it must still be parseable JSON.
BR=$ROOT/'br"anch\test'; mkproj "$BR" 2>/dev/null
CBR="$ROOT/br.md"; mkcp "$CBR" "QUOTES"
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
P15="$ROOT/p15"; mkproj "$P15"; C15="$ROOT/p15.md"; mkcp "$C15" "ANC"
eq "arm.sh refuses a symlinked context-cycle/ -> rc 1" "1" \
   "$( (cd "$P15" && CLAUDE_CONFIG_DIR="$(winp "$R15/cfg")" bash "$ARM" "$C15" >/dev/null 2>&1); echo $? )"
# Assert by NAME, not by count: the pre-fix arm.sh reaped the stale precious.json
# via its own `find -delete` and wrote a flag in its place, leaving the count at 1.
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
P16="$ROOT/p16"; mkproj "$P16"; C16="$ROOT/p16.md"; mkcp "$C16" "DOTFILES"
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
P17="$ROOT/p17"; mkproj "$P17"; C17="$ROOT/p17.md"; mkcp "$C17" "WRITE"
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
   "$([ -L "$DEST17" ] && echo LINK || { [ -f "$DEST17" ] && echo file || echo missing; })"
eq "the fallback still arms correctly" "WRITE" \
   "$(node -e 'const fs=require("fs");
      const a=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      console.log(fs.readFileSync(a.checkpoint,"utf8").match(/Working on: (\w+)/)[1])' "$DEST17" 2>/dev/null)"
# mktemp names are random, so the guarantee to assert is that none are left behind:
# a stranded temp would otherwise sit under a name the old *.json sweep never reaped.
eq "no temp file left behind" "0" \
   "$(ls -1a "$R17/cfg/context-cycle/armed.d" | grep -c '^\.tmp\.' || true)"
fi

echo "=== 18. install.sh: idempotent, and never silently reverts a local edit ==="
# The installer is the one component with no coverage at all, and its bare `cp`
# over an installed file is exactly how a patched copy used to vanish without a
# trace. Installs into a throwaway config dir; the repo clone is present, so the
# curl branch is never taken and this stays offline.
I="$(winp "$ROOT/inst")"; mkdir -p "$ROOT/inst"
inst() { (CLAUDE_CONFIG_DIR="$I" bash "$REPO/install.sh" 2>&1); }
OUT18=$(inst); eq "install exits 0" "0" "$?"
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
  C19="$ROOT/p19.md"; mkcp "$C19" "TWOFORMS"
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
  C20="$ROOT/p20.md"; mkcp "$C20" "CASEFOLD"
  (cd "$PU" && CLAUDE_CODE_SESSION_ID=ff20-1010 bash "$ARM" "$C20" >/dev/null 2>&1)
  eq "an arm in Pcase is not consumed by a clear in pcase" "" "$(clear_in "$PL")"
  eq "and that arm is still armed" "1" "$(arms)"
  eq "while the project it was armed in still restores" \
     '✓ Restored: "CASEFOLD" · next: finish CASEFOLD (testbr)' "$(clear_in "$PU")"
  rm -f "$ARMD"/*.json 2>/dev/null || true
else
  skip "group 20 case-collision scope matching" "this filesystem treats Proj and proj as one directory"
fi

echo
printf '=== %d passed, %d failed, %d skipped ===\n' "$PASS" "$FAIL" "$SKIP"
[ "$SKIP" -eq 0 ] || printf 'skipped on this platform (%s):%s\n' "$(uname -s 2>/dev/null || echo unknown)" "$SKIPPED"
[ "$FAIL" -eq 0 ]
