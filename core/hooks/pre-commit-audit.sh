#!/usr/bin/env bash
# Pre-commit self-audit gate for coding agents (Claude Code hook contract). Wired on PreToolUse with
# matcher "Bash"; the script itself decides whether the command is a
# `git commit` and stays silent otherwise.
#
# WHY THE SCRIPT SELF-FILTERS: the hook-entry `if` key is a prefix match
# on the command string, so `cd x && git commit` would not trigger it,
# and older Claude Code versions ignored the key entirely (which made the
# hook fire on every Bash call). Parsing tool_input.command here is
# correct on every version and catches every segment-anchored form. See
# pre-push-checklist.sh for the same rationale.
#
# Layer 1 (automated): LOC budget, console.log, bare TODO.
#   Violation -> DENY. Fix first, then commit.
#
# Layer 2 (contextual): detects money/PII/API/schema paths in
#   staged files and injects targeted ENGINEERING-PRINCIPLES.md
#   reminders so the agent self-audits the right sections.
#   Clean -> ALLOW with targeted context.
#
# This is the "audit before commit" gate. pre-push-checklist.sh is the
# "audit before push" gate. Together they enforce:
#   make changes -> self-audit -> fix -> commit -> push
#
# See also: senior-check-before.sh (UserPromptSubmit, mindset),
#           senior-check-after.sh  (Stop, response quality).
#
# UNIVERSAL: the LOC budget (400), the language extensions, and the
# Layer-2 path patterns below are generic defaults. Tune them to your
# project (add/remove file extensions, adjust the path regexes). The
# print-debug check is JS/TS-only because `print(` in Python or `fmt.Println`
# in Go are legitimate CLI output far more often than debug leftovers.

set -u

INPUT=$(cat)
FLAT=$(printf '%s' "$INPUT" | tr -d '\n')
CMD=$(printf '%s' "$FLAT" | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p')

# Only act on actual `git commit` invocations (same segment-anchored
# matcher as pre-push-checklist.sh). If the command cannot be extracted
# at all, run the audit anyway: it only denies on real staged-file
# violations, so a spurious run is benign and a silently dead gate is not.
if [ -n "$CMD" ] && ! printf '%s' "$CMD" | grep -qE '(^[[:space:]]*|[;&|(][[:space:]]*)git([[:space:]]+(-[^-[:space:];&|][^[:space:];&|]*([[:space:]]+[^-][^[:space:];&|]*)?|--[^[:space:];&|]+))*[[:space:]]+commit([[:space:]]|$|[;&|)])'; then
  printf '{}\n'
  exit 0
fi

# Audit the repo the commit runs in (the hook's cwd): a worktree session
# commits its own tree, not CLAUDE_PROJECT_DIR's.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  REPO="$(git rev-parse --show-toplevel 2>/dev/null)"
else
  REPO="${SENIOR_MODE_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-${CURSOR_PROJECT_DIR:-${GEMINI_PROJECT_DIR:-.}}}}"
fi
GIT_DIR_ARGS=(-C "$REPO")
STAGED=$(git "${GIT_DIR_ARGS[@]}" diff --staged --name-only 2>/dev/null || true)

if [ -z "$STAGED" ]; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "No staged changes detected. Stage files before committing (or this is a -a / pathspec commit; the audit only sees the index)."
  }
}
EOF
  exit 0
fi

# ── Layer 1: Automated checks (any fail → deny) ──────────────

# 1a. LOC budget: no staged source file over 400 without an exception
#     comment in its first 20 lines. Extend the extension list for your
#     stack. Deleted files are skipped (no file on disk).
LOC_BREACH=""
while IFS= read -r file; do
  abs="$REPO/$file"
  if [[ "$file" =~ \.(ts|tsx|js|jsx|mjs|cjs|py|go|rs|java|kt|rb|php|cs|swift)$ ]] && [ -f "$abs" ]; then
    LOC=$(wc -l < "$abs" | tr -d '[:space:]')
    if [ "$LOC" -gt 400 ]; then
      HAS_EX=$(head -20 "$abs" | grep -c "PRINCIPLES: max-lines-exception" || true)
      if [ "$HAS_EX" -eq 0 ]; then
        LOC_BREACH="yes"
        break
      fi
    fi
  fi
done <<< "$STAGED"

if [ -n "$LOC_BREACH" ]; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Pre-commit audit DENIED: a staged source file exceeds 400 LOC without an exception.\n\nRun wc -l on staged source files. Either:\n1. Split the file under 400 LOC\n2. Add a `PRINCIPLES: max-lines-exception: <reason>` comment in the first 20 lines (use the comment syntax of the file's language)\n\nENGINEERING-PRINCIPLES.md section 12a. Fix, re-stage, commit."
  }
}
EOF
  exit 0
fi

# 1b. console.log in staged JS/TS additions
# Only check JS/TS files so the hook's own message (which contains the
# literal "console.log(") doesn't self-trigger when staged. Operational
# scripts under scripts/ legitimately use console.log for stdout output
# (exclude them), and evals/ for the same reason (an eval runner is a CLI
# reporter; stdout IS its product).
JS_TS_STAGED=$(echo "$STAGED" \
  | grep -E '\.(js|jsx|mjs|cjs|ts|tsx)$' \
  | grep -vE '(^|/)(scripts|evals|bin)/' || true)
if [ -n "$JS_TS_STAGED" ]; then
  # set -f: the unquoted expansion below word-splits on purpose (one
  # token per staged path) but must NOT glob: route dirs like [id]
  # contain glob metacharacters.
  set -f
  CL_COUNT=$(git "${GIT_DIR_ARGS[@]}" diff --staged -U0 -- $JS_TS_STAGED 2>/dev/null | grep -c '^\+.*console\.log(' || true)
  set +f
else
  CL_COUNT=0
fi
if [ "$CL_COUNT" -gt 0 ]; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Pre-commit audit DENIED: console.log() in staged additions.\n\nRemove console.log from production code. Use a logger, or console.error/warn if needed.\n\nENGINEERING-PRINCIPLES.md section 12. Fix, re-stage, commit."
  }
}
EOF
  exit 0
fi

# 1c. TODO / FIXME without owner and date. Language-agnostic: matches the
#     marker after any common comment opener (// # -- /* <!--) when it is
#     NOT immediately followed by "(" (the required `TODO(owner, date)`
#     shape).
TODO_COUNT=$(git "${GIT_DIR_ARGS[@]}" diff --staged -U0 2>/dev/null | grep -cE '^\+.*(//|#|--|/\*|<!--)[[:space:]]*(TODO|FIXME)([^(]|$)' || true)
if [ "$TODO_COUNT" -gt 0 ]; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Pre-commit audit DENIED: TODO/FIXME without owner and date.\n\nRequired: TODO(owner, YYYY-MM-DD): description\n\nENGINEERING-PRINCIPLES.md section 12. Fix, re-stage, commit."
  }
}
EOF
  exit 0
fi

# ── Layer 2: Contextual reminders (pass, with targeted context) ──

MONEY=$(echo "$STAGED" | grep -cE '(billing|payment|payout|invoice|checkout|charge|refund|subscription|commission|ledger|wallet)' || true)
PII=$(echo "$STAGED" | grep -cE '(ssn|pii|bank|encrypt|sensitive|personal|kyc|identity)' || true)
API=$(echo "$STAGED" | grep -cE '(/api/|routes?/|controllers?/|handlers?/|endpoints?/)' || true)
SCHEMA=$(echo "$STAGED" | grep -cE '(schema/|migrations?/|migrate|models?/)' || true)
SERVICE=$(echo "$STAGED" | grep -cE '(services?/|domain/|usecases?/)' || true)

CTX="Pre-commit audit PASSED automated checks."

if [ "$MONEY" -gt 0 ]; then
  CTX="$CTX MONEY PATH touched: integer minor units (cents), wrap multi-step writes in a transaction, idempotency keys on anything retryable (EP section 6)."
fi
if [ "$PII" -gt 0 ]; then
  CTX="$CTX PII PATH touched: encrypt at rest, log sensitive reads, scrub from error reporters (EP section 7)."
fi
if [ "$API" -gt 0 ]; then
  CTX="$CTX API ROUTE touched: authenticate first, derive tenant/owner from the session not the body, validate input, rate limit; GET handlers never write (EP section 5, 8)."
fi
if [ "$SCHEMA" -gt 0 ]; then
  CTX="$CTX SCHEMA touched: tenant key on every owned table, additive migration, journal entry in the same commit (EP section 5)."
fi
if [ "$SERVICE" -gt 0 ]; then
  CTX="$CTX SERVICE touched: tenant scoping, access-control helpers (EP section 5)."
fi

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "$CTX"
  }
}
EOF
