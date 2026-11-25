#!/usr/bin/env bash
# Boundary probe: does any test notice when a boundary you just wrote
# moves by one?
#
#   bash .senior-mode/hooks/boundary-probe.sh [options] [file...]
#     --base <ref>     diff against this ref (default HEAD: uncommitted work)
#     --test "<cmd>"   the test command; {file} is replaced with the probed file
#     --max <n>        probe at most n boundaries (default 8)
#     --timeout <s>    seconds per test run (default 120)
#     --force          run although another session shares this checkout
#
# No tool can read `<` and know it should have been `<=`. An off by one is
# only wrong against what the code is for, and the one thing that pins
# that down is a test that goes red when the boundary moves. So this takes
# every comparison and every `+ 1` / `- 1` on the lines your diff added,
# flips one at a time (< to <=, >= to >, - 1 to - 0), and runs the tests.
#
#   KILLED     the tests went red. Something pins this boundary.
#   SURVIVED   the tests stayed green with the boundary moved. Nothing
#              checks it, so nothing says the line is right.
#
# It runs the unchanged tree first. A probe on a red suite proves nothing,
# so a red baseline stops it.
#
# The test command comes from --test, then SENIOR_MODE_TEST_RELATED_CMD,
# then `commands.test_related` or `commands.test` in the stack profile.
#
# It edits the file in place, one flip at a time, and puts it back after
# each run. Before every flip it records where the original is, so a run
# that is killed half way restores the file the next time it starts. Run
# it from your own worktree when another session shares the checkout.
#
# Exit code: 0 every flip was killed (or there was nothing to probe),
# 1 at least one survived, 2 it could not run.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/profile.sh
. "$HERE/lib/profile.sh"

BASE=HEAD; TESTCMD=""; MAX=8; TIMEOUT=120; FORCE=no; FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base)    BASE="${2:-HEAD}"; shift 2 ;;
    --test)    TESTCMD="${2:-}"; shift 2 ;;
    --max)     MAX="${2:-8}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-120}"; shift 2 ;;
    --force)   FORCE=yes; shift ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    -*)        echo "boundary-probe: unknown option $1"; exit 2 ;;
    *)         FILES+=("$1"); shift ;;
  esac
done
case "$MAX" in ''|*[!0-9]*) MAX=8 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=120 ;; esac

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "boundary-probe: not inside a git repository"; exit 2; }
GD=$(git rev-parse --absolute-git-dir 2>/dev/null)
STATE="$GD/senior-mode"
mkdir -p "$STATE" 2>/dev/null || { echo "boundary-probe: cannot write under $GD"; exit 2; }
RECOVER="$STATE/probe-restore"
LOCK="$STATE/probe.lock"
cd "$ROOT" || exit 2

restore() { # put the original back if a flip is in the tree
  [ -f "$RECOVER" ] || return 0
  local bk="" orig=""
  { IFS= read -r bk; IFS= read -r orig; } < "$RECOVER" 2>/dev/null || true
  if [ -n "$bk" ] && [ -n "$orig" ] && [ -f "$bk" ]; then
    if cp "$bk" "$orig" 2>/dev/null && cmp -s "$bk" "$orig"; then rm -f "$RECOVER" "$bk"; return 0; fi
    echo "boundary-probe: COULD NOT RESTORE $orig. The original is at $bk. Copy it back by hand."
    return 1
  fi
  rm -f "$RECOVER"
}
if [ -f "$RECOVER" ]; then
  echo "boundary-probe: an earlier run stopped half way. Restoring the file it was probing."
  restore || exit 2
fi

SESS="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/claude-sessions"
if [ "$FORCE" = no ] && [ -d "$SESS" ]; then
  LIVE=0; for s in "$SESS"/*.session; do [ -f "$s" ] && LIVE=$((LIVE + 1)); done
  if [ "$LIVE" -gt 1 ]; then
    echo "boundary-probe: $LIVE sessions are registered in this repo, and the probe edits files in place."
    echo "Run it from your own worktree, or pass --force when the others are not in this checkout."
    exit 2
  fi
fi
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "boundary-probe: another probe is running here ($LOCK). Remove that folder if it is stale."
  exit 2
fi
trap 'restore; rm -f "$STATE/probe-sites.$$" "$STATE/probe-run.log" 2>/dev/null; rmdir "$LOCK" 2>/dev/null' EXIT
trap 'exit 130' INT TERM

if [ -z "$TESTCMD" ]; then TESTCMD=$(sm_cmd "$ROOT" test_related); fi
if [ -z "$TESTCMD" ]; then TESTCMD=$(sm_cmd "$ROOT" test); fi
if [ -z "$TESTCMD" ]; then
  echo "boundary-probe: no test command is known for this repo."
  echo "Pass --test \"<command>\" ({file} is replaced with the probed file), or set SENIOR_MODE_TEST_RELATED_CMD."
  exit 2
fi

# ---- find the boundaries on added lines ------------------------------------------
# Output: file <TAB> line <TAB> column <TAB> from <TAB> to
SITES_AWK='
function quoted(prefix,   t, n) {
  t = prefix; n = gsub(/"/, "", t); if (n % 2) return 1
  t = prefix; n = gsub(/\047/, "", t); if (n % 2) return 1
  t = prefix; n = gsub(/`/, "", t); if (n % 2) return 1
  return 0
}
function flip(line, from, to,   i, after) {
  i = index(line, from)
  if (!i) return 0
  if (quoted(substr(line, 1, i - 1))) return 0
  if (from == " - 1" || from == " + 1") {
    after = substr(line, i + length(from), 1)
    if (after ~ /[0-9.]/) return 0
  }
  printf "%s\t%d\t%d\t%s\t%s\n", file, ln, i, from, to
  return 1
}
function site(line) {
  if (line ~ /^[ \t]*(\/\/|#|\*|\/\*)/) return
  if (flip(line, " <= ", " < ")) return
  if (flip(line, " >= ", " > ")) return
  if (flip(line, " < ", " <= ")) return
  if (flip(line, " > ", " >= ")) return
  if (flip(line, " - 1", " - 0")) return
  flip(line, " + 1", " + 0")
}
function wanted(f) {
  if (f !~ /\.(ts|tsx|mts|cts|js|jsx|mjs|cjs|py|go|rs|rb|java|kt|php|cs|swift)$/) return 0
  if (f ~ /(^|\/)(tests?|__tests__|spec|e2e|fixtures)\// || f ~ /\.(test|spec)\./ || f ~ /_test\.(go|py)$/ || f ~ /(^|\/)test_[^\/]*\.py$/) return 0
  return 1
}
whole == 1 { file = name; if (wanted(file)) { ln = NR; site($0) } next }
/^\+\+\+ / { file = $0; sub(/^\+\+\+ (b\/)?/, "", file); ok = wanted(file); next }
/^@@/ { if (match($0, /\+[0-9]+/)) ln = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
/^\+/ { if (ok) site(substr($0, 2)); ln++ }
'
SITES="$STATE/probe-sites.$$"
: > "$SITES"
if [ "${#FILES[@]}" -gt 0 ]; then
  git diff -U0 "$BASE" -- "${FILES[@]}" 2>/dev/null | awk "$SITES_AWK" >> "$SITES"
else
  git diff -U0 "$BASE" 2>/dev/null | awk "$SITES_AWK" >> "$SITES"
fi
# A file git has never seen has no diff: every line of it is new.
while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  if [ "${#FILES[@]}" -gt 0 ]; then
    hit=no; for want in "${FILES[@]}"; do [ "$want" = "$f" ] && hit=yes; done
    [ "$hit" = yes ] || continue
  fi
  awk -v whole=1 -v name="$f" "$SITES_AWK" "$f" >> "$SITES"
done <<EOF
$(git ls-files --others --exclude-standard 2>/dev/null)
EOF

TOTAL=$(wc -l < "$SITES" | tr -d '[:space:]')
if [ "${TOTAL:-0}" -eq 0 ]; then
  rm -f "$SITES"
  echo "boundary-probe: no comparison and no +1 or -1 on the lines changed against $BASE. Nothing to probe."
  echo "PROBE_EXIT=0"
  exit 0
fi
echo "boundary-probe: $TOTAL boundaries on the changed lines, probing up to $MAX."
echo "test command: $TESTCMD"

LOG="$STATE/probe-run.log"
run_tests() { # <file> -> exit code of the test command
  local cmd=${TESTCMD//\{file\}/$1}
  (cd "$ROOT" && sm_budget "$TIMEOUT" "$LOG" bash -c "$cmd")
}

SURVIVED=0; KILLED=0; PROBED=0; BASE_OK=""; BASE_RED=""
TAB=$(printf '\t')
while IFS="$TAB" read -r f ln col from to; do
  [ "$PROBED" -lt "$MAX" ] || break
  # One baseline per file when the command names the file, one for the
  # whole run when it does not.
  case "$TESTCMD" in *'{file}'*) key="$f" ;; *) key="(all)" ;; esac
  case " $BASE_RED " in *" $key "*) continue ;; esac
  case " $BASE_OK " in
    *" $key "*) ;;
    *)
      run_tests "$f"; rc=$?
      if [ "$rc" -ne 0 ]; then
        BASE_RED="$BASE_RED $key"
        echo "  BASELINE RED ($rc) for $key: the tests fail before any flip, so a flip proves nothing. Last lines:"
        tail -n 8 "$LOG" 2>/dev/null | sed 's/^/    /'
        continue
      fi
      BASE_OK="$BASE_OK $key" ;;
  esac
  BK="$STATE/probe-original.$$"
  cp "$f" "$BK" || { echo "boundary-probe: cannot back up $f"; exit 2; }
  printf '%s\n%s\n' "$BK" "$ROOT/$f" > "$RECOVER"
  awk -v n="$ln" -v c="$col" -v from="$from" -v to="$to" \
    'NR == n && substr($0, c, length(from)) == from { $0 = substr($0, 1, c - 1) to substr($0, c + length(from)) } { print }' "$BK" > "$f"
  run_tests "$f"; rc=$?
  restore || exit 2
  PROBED=$((PROBED + 1))
  if [ "$rc" -eq 0 ]; then
    SURVIVED=$((SURVIVED + 1)); echo "  SURVIVED  $f:$ln  '$from' -> '$to'"
  elif [ "$rc" -eq 124 ]; then
    KILLED=$((KILLED + 1));   echo "  KILLED    $f:$ln  '$from' -> '$to'  (the tests ran past ${TIMEOUT}s)"
  else
    KILLED=$((KILLED + 1));   echo "  KILLED    $f:$ln  '$from' -> '$to'"
  fi
done < "$SITES"
rm -f "$SITES" "$LOG"

echo
if [ "$PROBED" -eq 0 ]; then
  echo "boundary-probe: nothing was probed. Fix the red baseline first."
  echo "PROBE_EXIT=2"
  exit 2
fi
[ "$TOTAL" -gt "$PROBED" ] && echo "$((TOTAL - PROBED)) more boundaries were not probed (raise --max to reach them)."
if [ "$SURVIVED" -eq 0 ]; then
  echo "All $KILLED flips turned the tests red. Each of those boundaries is pinned by a test."
  echo "PROBE_EXIT=0"
  exit 0
fi
echo "$SURVIVED of $PROBED flips stayed green. No test fails when those boundaries move by one, so no test says they are right."
echo "For each one, write the test at the edge (the empty case, exactly at the limit, one past it), then run this again."
[ "$KILLED" -eq 0 ] && echo "Every flip survived. Check that the test command runs tests that import these files at all."
echo "PROBE_EXIT=1"
exit 1
