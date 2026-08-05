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

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/context-cycle-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export CLAUDE_CONFIG_DIR="$ROOT/cfg"
ARMD="$CLAUDE_CONFIG_DIR/context-cycle/armed.d"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

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
clear_in() {
  local out
  out=$(printf '{"source":"clear","cwd":"%s","session_id":"post-clear-new-uuid"}' "$1" | node "$HOOK")
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
{ "checkpoint": "$C5", "branch": "main", "cwd": "$P5", "armed_at": $(date +%s) }
EOF
eq "legacy arm is consumed" '✓ Restored: "LEGACY" · next: finish LEGACY (main)' "$(clear_in "$P5")"
eq "legacy file deleted" "absent" "$([ -e "$CLAUDE_CONFIG_DIR/context-cycle/armed.json" ] && echo present || echo absent)"

echo "=== 6. Corrupt / old-format garbage never crashes ==="
printf 'not json at all {{{' > "$CLAUDE_CONFIG_DIR/context-cycle/armed.json"
OUT=$(printf '{"source":"clear","cwd":"%s"}' "$P5" | node "$HOOK" 2>"$ROOT/err6"); RC=$?
eq "exit 0 on garbage" "0" "$RC"
eq "no stdout on garbage" "" "$OUT"
eq "no stderr on garbage" "" "$(cat "$ROOT/err6")"
touch -d '3 hours ago' "$CLAUDE_CONFIG_DIR/context-cycle/armed.json"
printf '{"source":"startup","cwd":"%s"}' "$P5" | node "$HOOK" >/dev/null 2>&1
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
rm -f "$ARMD"/*.json

echo "=== 8. TTL: a stale arm is swept, never restored ==="
P8="$ROOT/p8"; mkproj "$P8"; C8="$ROOT/p8.md"; mkcp "$C8" "STALE"
mkdir -p "$ARMD"
cat > "$ARMD/deadbeef1234-oldsess.json" <<EOF
{ "checkpoint": "$C8", "branch": "", "cwd": "$P8", "armed_at": $(( $(date +%s) - 7200 )) }
EOF
eq "stale arm does not restore" "" "$(clear_in "$P8")"
eq "stale arm swept from disk"  "0" "$(arms)"

echo "=== 9. Non-clear session starts never consume the arm ==="
P9="$ROOT/p9"; mkproj "$P9"; C9="$ROOT/p9.md"; mkcp "$C9" "KEEP"
(cd "$P9" && CLAUDE_CODE_SESSION_ID=s9 bash "$ARM" "$C9" >/dev/null 2>&1)
eq "source=startup: silent"  "" "$(printf '{"source":"startup","cwd":"%s"}' "$P9" | hook_raw)"
eq "source=resume: silent"   "" "$(printf '{"source":"resume","cwd":"%s"}' "$P9" | hook_raw)"
eq "source=compact: silent"  "" "$(printf '{"source":"compact","cwd":"%s"}' "$P9" | hook_raw)"
eq "arm survived all three"  "1" "$(arms)"

echo "=== 10. Unreadable/empty payload fails CLOSED (was: fired a restore) ==="
eq "empty stdin: silent"      "" "$(hook_raw < /dev/null)"
eq "garbage stdin: silent"    "" "$(printf 'not-json' | hook_raw)"
eq "payload with no source: silent" "" "$(printf '{"cwd":"%s"}' "$P9" | hook_raw)"
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
BEFORE=$(ls -1 "$ROOT"/*.md | wc -l)
(cd "$P12" && CLAUDE_CODE_SESSION_ID=s12c bash "$ARM" "$K" >/dev/null 2>&1)
clear_in "$P12" >/dev/null
eq "checkpoint files never deleted by a restore" "$BEFORE" "$(ls -1 "$ROOT"/*.md | wc -l)"

echo "=== 13. Payload shape: full multi-KB checkpoint survives writeSync ==="
P13="$ROOT/p13"; mkproj "$P13"; C13="$ROOT/p13.md"
{ printf '## Working on: BIG\n\n### Remaining Work\n1. finish BIG\n\n'
  for i in $(seq 1 400); do printf 'padding line %d with some prose to make this multi-KB\n' "$i"; done; } > "$C13"
(cd "$P13" && CLAUDE_CODE_SESSION_ID=s13 bash "$ARM" "$C13" >/dev/null 2>&1)
RES=$(printf '{"source":"clear","cwd":"%s"}' "$P13" | node "$HOOK" | jsonf shape)
eq "valid JSON, complete, truncation-noted" "SessionStart true true true" "$RES"
eq "checkpoint size on disk" "1" "$([ "$(wc -c < "$C13")" -gt 9000 ] && echo 1 || echo 0)"

echo
printf '=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
