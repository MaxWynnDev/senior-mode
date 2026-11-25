#!/usr/bin/env bash
# Exit-code mask guard for coding agents (Claude Code hook contract). Wired on PreToolUse / Bash.
#
# Blocks three command shapes that turn a RED check into a reported green.
#
# 1. Piping a CI watcher through anything (`gh run watch ... | tail`,
#    `| head`, `| grep`). A pipeline's exit status is the LAST command's,
#    so the watcher's failure vanishes and the session reports a red build
#    as green. In one project this happened five times in two months, once
#    reporting three consecutive red pushes as shipped. A memory note did
#    not stop it; a hook does.
#
#    The sanctioned recipe (redirect, never pipe; print BOTH signals):
#      gh run watch <id> --exit-status > watch.log 2>&1; echo "WATCH_EXIT=$?"
#      gh run view <id> --json status,conclusion
#    The `conclusion` field is the fact. `--exit-status` alone treats a
#    CANCELLED run as neither success nor failure (exit 0), so read the
#    conclusion even when the watcher exits clean.
#
# 2. `|| true` (or `|| :`) straight after a type checker, a linter or a
#    test runner. The command can no longer fail, so its green proves
#    nothing. `|| echo red` is left alone: that reports the failure.
#
# 3. `tsc` with source files on the command line in a repo that has a
#    tsconfig.json. The TypeScript handbook: "When input files are
#    specified on the command line, tsconfig.json files are ignored." The
#    files get checked under default options, not the project's, so the
#    result says nothing about the project. `-p` / `--project` and
#    `-b` / `--build` runs are fine.
#
# Fail-open on anything uncertain: a missed block is recoverable; a guard
# that wedged unrelated pipes is worse.

set -u

INPUT=$(cat)
FLAT=$(printf '%s' "$INPUT" | tr -d '\n')
CMD=$(printf '%s' "$FLAT" | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p')

[ -n "$CMD" ] || { printf '{}\n'; exit 0; }

# ---- 1. a piped CI watcher ----------------------------------------------------
WATCHER=""
case "$CMD" in
  *"gh run watch"*)   WATCHER="gh run watch" ;;
  *"gh pr checks"*)   case "$CMD" in *"--watch"*) WATCHER="gh pr checks" ;; esac ;;
esac
if [ -n "$WATCHER" ]; then
  # A pipe on the watcher masks its exit code. Look at the watcher's own
  # shell segment only: it ends at the first ; && || or line break (\n in
  # the JSON payload). Without the cut, a pipe in a later command was read
  # as a pipe on the watcher, so the redirect recipe followed by
  # `gh run view --jq '.jobs[] | .name'` was denied, and so was `|| echo red`.
  TAIL_OF_CMD=${CMD#*"$WATCHER"}
  TAIL_OF_CMD=${TAIL_OF_CMD%%;*}
  TAIL_OF_CMD=${TAIL_OF_CMD%%&&*}
  TAIL_OF_CMD=${TAIL_OF_CMD%%||*}
  TAIL_OF_CMD=${TAIL_OF_CMD%%\\n*}
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
fi

deny() { # <reason: no double quotes, \n for a line break>
  printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "PreToolUse",\n    "permissionDecision": "deny",\n    "permissionDecisionReason": "%s"\n  }\n}\n' "$1"
  exit 0
}

# The two checks below read a command that starts a shell segment, so a
# checker's name inside a commit message or an echo is not a hit. The
# command is still JSON-escaped here: a line break is a backslash and an n.
SEG='(^|[;&|(]|\\n)[[:space:]]*'
VIA='((npx|pnpm|yarn|bunx?|npm)[[:space:]]+(exec[[:space:]]+)?)?'
TOOL='(tsc|pyright|mypy|eslint|ruff[[:space:]]+check|pytest|vitest|jest|go[[:space:]]+(vet|build|test)|cargo[[:space:]]+(check|test|clippy))'
SCRIPT='(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?(typecheck|type-check|lint|test)'
# The rest of the segment up to the ||, redirects such as 2>&1 included.
REST='([:[:space:]]([^;&|]|>&|&>)*)?'
MASK='\|\|[[:space:]]*(true|:)([[:space:]]|$|[;&|)\\])'

# ---- 2. a checker that cannot fail ----------------------------------------------
if printf '%s' "$CMD" | grep -qE "${SEG}(${VIA}${TOOL}|${SCRIPT})${REST}${MASK}"; then
  deny 'BLOCKED: `|| true` after a checker throws its exit code away, so a red run reads as exit 0 and the green proves nothing. Run it bare. To keep going after a failure and still see it, redirect and print the code:\n  <the check> > check.log 2>&1; echo CHECK_EXIT=$?\nor run bash .senior-mode/hooks/check.sh, which does that and records the result.'
fi

# ---- 3. tsc with files, where a tsconfig exists ---------------------------------
TSC="${SEG}${VIA}tsc[[:space:]]"
if printf '%s' "$CMD" | grep -qE "${TSC}[^;&|]*\\.(ts|tsx|mts|cts)([[:space:]]|\$|[;&|)'\\\\])" \
   && ! printf '%s' "$CMD" | grep -qE "${TSC}([^;&|]*[[:space:]])?(-p|--project|-b|--build)([[:space:]=]|\$)"; then
  ROOT="${SENIOR_MODE_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-${CURSOR_PROJECT_DIR:-${GEMINI_PROJECT_DIR:-.}}}}"
  if [ -f tsconfig.json ] || [ -f "$ROOT/tsconfig.json" ]; then
    deny 'BLOCKED: tsc was given source files and this repo has a tsconfig.json. With files on the command line tsc ignores the tsconfig, so they are checked under default options and the result says nothing about the project. Run the project check (tsc --noEmit -p . or the repo typecheck script), or bash .senior-mode/hooks/check.sh.'
  fi
fi

printf '{}\n'
exit 0
