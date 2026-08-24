#!/usr/bin/env bash
# Pre-push gate for coding agents (Claude Code hook contract). Wired on PreToolUse with matcher "Bash";
# the script itself decides whether the command is a `git push` and stays
# silent otherwise. It rejects a push when the HEAD commit is missing a
# `Senior-Checklist:` trailer (or the trailer is malformed).
#
# WHY THE SCRIPT SELF-FILTERS: current Claude Code versions support an
# `"if": "Bash(git push *)"` key on a hook entry, but that is a PREFIX
# match on the command string. `cd x && git push`, `(git push)`, and
# `git -C <dir> push` would all sail past it, and those are exactly the
# forms a gate must catch. Older versions ignored the key entirely, which
# made the hook fire on every Bash call and, worse, set the push-done
# sentinel that tells the Stop-hook self-audit to skip. Parsing
# tool_input.command here is correct on every version and catches every
# segment-anchored form.
#
# Required trailer format (single line in the commit message):
#
#   Senior-Checklist: ambiguity=<grade> summary=<grade> concurrency=<grade> regression=<grade> blast=<grade>
#
# Allowed grades per key: pass | miss | n/a
# (key `blast` also accepts green | red: the deploy/blast-radius consequence.)
#
# A `miss` is allowed but is a conscious acknowledgement; missing keys
# are not. The point is to make the senior self-check happen at commit
# time, when the thinking should happen anyway, and gate the
# irreversible action (push, which on many setups triggers a deploy).
#
# WHICH COMMIT IS CHECKED: the HEAD of the repo the command runs in (the
# hook's cwd), NOT CLAUDE_PROJECT_DIR. Those differ for every worktree
# session; reading the main checkout's HEAD from a worktree both blocked
# compliant worktree commits and, worse, would PASS a non-compliant one
# whenever the main checkout's unrelated HEAD happened to be fine. A gate
# that reads the wrong commit is not a gate.
#
# Detection notes:
# - Catches `git push`, `git -C <dir> push`, `git -c k=v push`,
#   `cd x && git push`, `(git push)`, `echo y | git push`.
# - An env-var prefix (`GIT_TRACE=1 git push`) is NOT caught; pushes are
#   not normally written that way. If the command cannot be extracted
#   from the payload at all (future payload-shape change), the gate runs
#   anyway: fail closed, never silently dead.
# - HEAD only. Multi-commit pushes are not validated per commit. To
#   validate every commit, walk `git rev-list @{u}..HEAD`.
#
# UNIVERSAL: the checklist keys are a generic senior self-review set.
# Rename/add keys to fit your project; keep the parser and key list in
# sync, and update test-checklist.sh.

# Intentionally not `set -e` / `pipefail`: a grep with no match exits
# non-zero, which is normal control flow here (key missing -> emit_deny).
set -u

INPUT=$(cat)
FLAT=$(printf '%s' "$INPUT" | tr -d '\n')

SESSION_ID=$(printf '%s' "$FLAT" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
CMD=$(printf '%s' "$FLAT" | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p')

# Is this Bash call actually a `git push`? Match "git", then any git
# options (-C <dir>, -c k=v, --flags), then the verb "push" at the start
# of any shell segment. JSON escapes inside $CMD do not affect this.
is_git_push=no
if [ -z "$CMD" ]; then
  # Could not extract the command: fail closed and validate anyway. A
  # spurious validation is loud; a silently dead gate is not.
  is_git_push=yes
elif printf '%s' "$CMD" | grep -qE '(^[[:space:]]*|[;&|(][[:space:]]*)git([[:space:]]+(-[^-[:space:];&|][^[:space:];&|]*([[:space:]]+[^-][^[:space:];&|]*)?|--[^[:space:];&|]+))*[[:space:]]+push([[:space:]]|$|[;&|)])'; then
  is_git_push=yes
fi

if [ "$is_git_push" = "no" ]; then
  printf '{}\n'
  exit 0
fi

# Validate the commit being PUSHED: the repo the push runs from. The hook's
# cwd is the session's repo, so ask git there. Fall back to
# CLAUDE_PROJECT_DIR only when cwd is not a work tree at all.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  PUSH_REPO="$(git rev-parse --show-toplevel 2>/dev/null)"
else
  PUSH_REPO="${SENIOR_MODE_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-${CURSOR_PROJECT_DIR:-${GEMINI_PROJECT_DIR:-.}}}}"
fi

MSG=$(git -C "$PUSH_REPO" log -1 --format=%B HEAD 2>/dev/null || true)
TRAILER=$(printf '%s\n' "$MSG" | grep -E '^Senior-Checklist:' | tail -1 || true)

# Hardcoded deny reasons (no dynamic content -> no JSON escaping
# headaches). `\n` sequences render as real line breaks in the
# permissionDecisionReason shown back to the model.
DENY_MISSING='Push blocked: HEAD commit missing Senior-Checklist trailer.\n\nAmend the commit to add a trailer line at the bottom:\n  Senior-Checklist: ambiguity=pass summary=pass concurrency=n/a regression=pass blast=green\n\nGrades per key: pass | miss | n/a (blast also accepts green | red).\nThe checklist itself: AMBIGUITY, SUMMARY, CONCURRENCY, REGRESSION, BLAST RADIUS.\nSee .senior-mode/hooks/pre-push-checklist.sh for the full spec.'

DENY_INCOMPLETE='Push blocked: Senior-Checklist trailer is missing one of the required keys or has an invalid grade.\n\nRequired keys (all 5): ambiguity, summary, concurrency, regression, blast\nGrades per key: pass | miss | n/a (blast also accepts green | red).\n\nRun `git log -1` to see your trailer, then `git commit --amend` to fix it.'

emit_deny() {
  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "$1"
  }
}
EOF
  exit 0
}

if [ -z "$TRAILER" ]; then
  emit_deny "$DENY_MISSING"
fi

# Strip the prefix and normalise whitespace so the per-key regex below
# can rely on space-delimited tokens.
PARSED=" $(printf '%s' "${TRAILER#Senior-Checklist:}" | tr -s '[:space:]' ' ') "

REQUIRED_KEYS=(ambiguity summary concurrency regression blast)
for key in "${REQUIRED_KEYS[@]}"; do
  val=$(printf '%s' "$PARSED" | grep -oE " $key=[a-zA-Z/-]+" | head -1 | sed -E "s|^ $key=||")
  if [ -z "$val" ]; then
    emit_deny "$DENY_INCOMPLETE"
  fi
  case "$val" in
    pass|miss|n/a|n-a) ;;
    green|red)
      [ "$key" = "blast" ] || emit_deny "$DENY_INCOMPLETE"
      ;;
    *) emit_deny "$DENY_INCOMPLETE" ;;
  esac
done

# All keys present and valid: allow the push.
# Set the SESSION-SCOPED push-done sentinel so senior-check-after.sh
# skips the after-check on this turn (the code is already shipping; a
# post-push audit finding would create a fix-forward commit + push
# loop). Session scoping keeps concurrent agent sessions from
# clearing each other's flags.
touch "${TMPDIR:-/tmp}/claude-push-done-${SESSION_ID:-unknown}" 2>/dev/null || true

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "Senior-Checklist trailer validated on HEAD commit. Push proceeding."
  }
}
EOF
