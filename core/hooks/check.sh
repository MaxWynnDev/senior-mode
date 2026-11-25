#!/usr/bin/env bash
# Runs the repo's full check and writes a receipt for it.
#
#   bash .senior-mode/hooks/check.sh [typecheck|lint|test]     default: typecheck
#
# post-edit-check.sh looks at the file that was just edited. An edit can
# also break a caller in a file nobody opened, and only the whole-project
# check sees that. This runs it the one way that can't lie about the
# result: output to a log, exit code read straight from the command, no
# pipe in between.
#
# The command comes from SENIOR_MODE_<KEY>_CMD, then the stack profile's
# `commands`, then (typecheck only) a package.json script named typecheck.
# See lib/profile.sh.
#
# The receipt is <git dir>/senior-mode/receipt-<key>:
#   rc=<exit code>
#   time=<epoch seconds>
#   cmd=<the command>
# and the full output is beside it in check-<key>.log. senior-check-after.sh
# compares the receipt's age with the last edit of the turn. A receipt
# older than the last edit means the tree was checked before it changed.
#
# Exit code: the command's own. 2 when no command is known.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/profile.sh
. "$HERE/lib/profile.sh"

KEY="${1:-typecheck}"
case "$KEY" in typecheck|lint|test) ;; *) echo "check.sh: unknown check '$KEY' (typecheck, lint or test)"; exit 2 ;; esac

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$ROOT" ] || ROOT="${SENIOR_MODE_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-.}}"
GD=$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)

case "$KEY" in
  typecheck) CMD=$(sm_cmd "$ROOT" typecheck) ;;
  lint)      CMD="${SENIOR_MODE_LINT_CMD:-}"; [ -n "$CMD" ] || { PF=$(sm_profile_file "$ROOT"); [ -n "$PF" ] && CMD=$(sm_json_string "$PF" lint); } ;;
  test)      CMD=$(sm_cmd "$ROOT" test) ;;
esac
case "${CMD:-}" in *'<'*'>'*) CMD="" ;; esac
if [ -z "${CMD:-}" ]; then
  UP=$(printf '%s' "$KEY" | tr '[:lower:]' '[:upper:]')
  echo "check.sh: no $KEY command is known for this repo."
  echo "Set SENIOR_MODE_${UP}_CMD, or install a stack profile (its profile.json carries one)."
  exit 2
fi

if [ -n "$GD" ]; then DIR="$GD/senior-mode"; else DIR="${TMPDIR:-/tmp}/senior-mode-check"; fi
mkdir -p "$DIR" 2>/dev/null || true
LOG="$DIR/check-$KEY.log"
RECEIPT="$DIR/receipt-$KEY"

echo "check.sh: $CMD"
START=$(date +%s)
(cd "$ROOT" && bash -c "$CMD") > "$LOG" 2>&1
RC=$?
END=$(date +%s)

printf 'rc=%s\ntime=%s\ncmd=%s\n' "$RC" "$END" "$CMD" > "$RECEIPT" 2>/dev/null || true

LINES=$(wc -l < "$LOG" | tr -d '[:space:]')
if [ "${LINES:-0}" -gt 80 ]; then
  echo "(last 80 of $LINES lines; the full log is $LOG)"
  tail -n 80 "$LOG"
else
  cat "$LOG"
fi
echo "CHECK_EXIT=$RC ($((END - START))s, $KEY)"
exit "$RC"
