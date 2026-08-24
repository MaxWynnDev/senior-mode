#!/usr/bin/env bash
# Exit-code mask guard for coding agents (Claude Code hook contract). Wired on PreToolUse / Bash.
#
# Blocks one command shape that repeatedly turns a RED CI run into a
# reported "exit code 0": piping a CI watcher through anything
# (`gh run watch ... | tail`, `| head`, `| grep`). A pipeline's exit
# status is the LAST command's, so the watcher's failure vanishes and the
# session reports a red build as green. In one project this happened five
# times in two months, once reporting three consecutive red pushes as
# shipped. A memory note did not stop it; a hook does.
#
# The sanctioned recipe (redirect, never pipe; print BOTH signals):
#   gh run watch <id> --exit-status > watch.log 2>&1; echo "WATCH_EXIT=$?"
#   gh run view <id> --json status,conclusion
# The `conclusion` field is the fact. `--exit-status` alone treats a
# CANCELLED run as neither success nor failure (exit 0), so read the
# conclusion even when the watcher exits clean.
#
# Fail-open on anything uncertain: a missed block is recoverable; a guard
# that wedged unrelated pipes is worse.

set -u

INPUT=$(cat)
FLAT=$(printf '%s' "$INPUT" | tr -d '\n')
CMD=$(printf '%s' "$FLAT" | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p')

[ -n "$CMD" ] || { printf '{}\n'; exit 0; }

WATCHER=""
case "$CMD" in
  *"gh run watch"*)   WATCHER="gh run watch" ;;
  *"gh pr checks"*)   case "$CMD" in *"--watch"*) WATCHER="gh pr checks" ;; esac ;;
esac
[ -n "$WATCHER" ] || { printf '{}\n'; exit 0; }

# Anything after the watcher that pipes its output masks the exit code.
TAIL_OF_CMD=${CMD#*"$WATCHER"}
case "$TAIL_OF_CMD" in
  *"|"*)
    cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: piping a CI watcher masks the run's exit code with the pipe's last command (a red run reads as exit 0). Use the redirect recipe instead:\n  gh run watch <id> --exit-status > watch.log 2>&1; echo \"WATCH_EXIT=$?\"\n  gh run view <id> --json status,conclusion\nThe conclusion field is the fact: success is green; cancelled, skipped, and null are NOT."
  }
}
EOF
    exit 0
    ;;
esac
printf '{}\n'
exit 0
