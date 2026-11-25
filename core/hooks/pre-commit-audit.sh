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
# Layer 1 (automated): LOC budget, console.log, bare TODO, a new checker
#   suppression with no reason, a loosened checker config, staged source
#   that fails the parse-level code check (post-edit-check.sh --plain).
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
# A commit may carry variable assignments in front (GIT_AUTHOR_DATE=... git
# commit). It is still a commit, and the override in check 1g is one of them.
if [ -n "$CMD" ] && ! printf '%s' "$CMD" | grep -qE '(^[[:space:]]*|[;&|(][[:space:]]*)([A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*[[:space:]]+)*git([[:space:]]+(-[^-[:space:];&|][^[:space:];&|]*([[:space:]]+[^-][^[:space:];&|]*)?|--[^[:space:];&|]+))*[[:space:]]+commit([[:space:]]|$|[;&|)])'; then
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

# The commit may do its own staging: `git add ... && git commit`, or
# `git commit -a`. That is how agents usually commit, and the real index
# holds none of those files when this hook runs, so reading it alone let
# every such commit through unaudited. Build the index the commit will
# see in a scratch copy and audit that. The real index is never touched.
# Anything this can't replay with certainty (a variable, a command
# substitution, `git add -p`) falls back to the real index.
ADD_MODE=none
ADD_PATHS=()
if printf '%s' "$CMD" | grep -qE '(^[[:space:]]*|[;&|(][[:space:]]*)git[[:space:]]+commit([[:space:]]+[^;&|]*)?[[:space:]](-[a-zA-Z]*a[a-zA-Z]*|--all)([[:space:]]|$)'; then
  ADD_MODE=update
fi
ADD_SEG=$(printf '%s' "$CMD" | sed -nE 's/.*(^|[;&|(][[:space:]]*)git[[:space:]]+add[[:space:]]+([^;&|]*).*/\2/p')
if [ -n "$ADD_SEG" ]; then
  [ "$ADD_MODE" = update ] || ADD_MODE=paths
  set -f
  for tok in $ADD_SEG; do
    # The command is still JSON-escaped: a quoted path arrives as \"a.ts\".
    tok=${tok#\\\"}; tok=${tok%\\\"}; tok=${tok#\'}; tok=${tok%\'}
    case "$tok" in
      -A|--all)            ADD_MODE=all ;;
      -u|--update)         [ "$ADD_MODE" = all ] || ADD_MODE=update ;;
      --|-f|--force|-v|--verbose) ;;
      -*|*'$'*|*'`'*|*\\*) ADD_MODE=none; ADD_PATHS=(); break ;;
      '') ;;
      *)                   ADD_PATHS+=("$tok") ;;
    esac
  done
  set +f
  if [ "$ADD_MODE" = paths ] && [ "${#ADD_PATHS[@]}" -eq 0 ]; then ADD_MODE=none; fi
fi
if [ "$ADD_MODE" != none ]; then
  GITDIR=$(git "${GIT_DIR_ARGS[@]}" rev-parse --absolute-git-dir 2>/dev/null || true)
  if [ -n "$GITDIR" ]; then
    SCRATCH_INDEX="$GITDIR/senior-audit-index.$$"
    trap 'rm -f "$SCRATCH_INDEX" "$SCRATCH_INDEX.lock" 2>/dev/null' EXIT
    [ -f "$GITDIR/index" ] && cp "$GITDIR/index" "$SCRATCH_INDEX" 2>/dev/null
    replayed=no
    case "$ADD_MODE" in
      all)    GIT_INDEX_FILE="$SCRATCH_INDEX" git "${GIT_DIR_ARGS[@]}" add -A >/dev/null 2>&1 && replayed=yes ;;
      update) GIT_INDEX_FILE="$SCRATCH_INDEX" git "${GIT_DIR_ARGS[@]}" add -u >/dev/null 2>&1 && replayed=yes
              if [ "$replayed" = yes ] && [ "${#ADD_PATHS[@]}" -gt 0 ]; then
                GIT_INDEX_FILE="$SCRATCH_INDEX" git add -- "${ADD_PATHS[@]}" >/dev/null 2>&1 || true
              fi ;;
      paths)  GIT_INDEX_FILE="$SCRATCH_INDEX" git add -- "${ADD_PATHS[@]}" >/dev/null 2>&1 && replayed=yes ;;
    esac
    # Every `git diff --staged` below now reads the scratch index.
    [ "$replayed" = yes ] && export GIT_INDEX_FILE="$SCRATCH_INDEX"
  fi
fi

STAGED=$(git "${GIT_DIR_ARGS[@]}" diff --staged --name-only 2>/dev/null || true)

if [ -z "$STAGED" ]; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "No staged changes detected. Stage files before committing (or this commit stages in a way the audit could not replay; it then only sees the index)."
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

# The three checks below name files and lines, so their reasons are built
# at run time. Double quotes become single quotes: the Cursor and Gemini
# shims re-embed the reason in their own JSON.
jtxt() { local s="$1" q="'"; s=${s//\\/\\\\}; s=${s//\"/$q}; s=${s//$'\t'/ }; s=${s//$'\r'/}; s=${s//$'\n'/\\n}; printf '%s' "$s"; }
deny() {
  printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "PreToolUse",\n    "permissionDecision": "deny",\n    "permissionDecisionReason": "%s"\n  }\n}\n' "$(jtxt "$1")"
  exit 0
}

# 1d. A new suppression with no reason on it. Silencing the checker to get
#     green is the same move as deleting a failing test, so it gets the
#     same answer: the reason goes in the code, where the next reader
#     sees it. Tests may cast to any (bad input on purpose is their job).
SUPP=$(git "${GIT_DIR_ARGS[@]}" diff --staged -U0 2>/dev/null | awk '
  function comment_only(s) { return (s ~ /^[ \t]*(\/\/|#|\*|\/\*)/) }
  /^\+\+\+ / { file = $0; sub(/^\+\+\+ (b\/)?/, "", file); prev = ""; next }
  /^@@/ { prev = ""; if (match($0, /\+[0-9]+/)) ln = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
  /^\+/ {
    line = substr($0, 2); hit = ""
    if (file ~ /\.(ts|tsx|mts|cts|js|jsx|mjs|cjs)$/) {
      if (line ~ /@ts-ignore/) hit = "@ts-ignore (use @ts-expect-error and put the reason after it)"
      else if (line ~ /@ts-nocheck/) hit = "@ts-nocheck"
      else if (line ~ /@ts-expect-error[ \t]*(\*\/)?[ \t]*$/) hit = "@ts-expect-error with no reason after it"
      else if (line ~ /eslint-disable/ && line !~ /eslint-disable.* -- /) hit = "eslint-disable with no -- reason"
      else if (file ~ /\.(ts|tsx|mts|cts)$/ && file !~ /\.d\.ts$/ && file !~ /\.(test|spec)\./ && file !~ /(^|\/)(tests?|__tests__|__mocks__|e2e|fixtures|mocks)\// && (line ~ / as any([^a-zA-Z0-9_]|$)/ || line ~ / as unknown as /) && line !~ /(\/\/|\/\*)/ && !comment_only(prev)) hit = "a cast to any with no comment saying why"
    } else if (file ~ /\.pyi?$/) {
      if (line ~ /#[ \t]*type:[ \t]*ignore([^\[]|$)/) hit = "a bare type: ignore (name the error code in brackets)"
      else if (line ~ /#[ \t]*noqa([^:]|$)/) hit = "a bare noqa (name the rule after a colon)"
      else if (line ~ /#[ \t]*pyright:[ \t]*ignore([^\[]|$)/) hit = "a bare pyright: ignore (name the rule in brackets)"
    } else if (file ~ /\.go$/) {
      if (line ~ /\/\/[ \t]*nolint([^:]|$)/) hit = "a bare nolint (name the linter after a colon)"
    }
    if (hit != "" && n < 6) { n++; printf "%s:%d: %s\n", file, ln, hit }
    prev = line; ln++
  }' || true)

# 1e. A staged change that makes the checker accept more: a strict flag
#     turned off, build errors ignored, a tsconfig exclude that grew. A
#     comment on the same line saying why lets it through.
LOOSE=$(git "${GIT_DIR_ARGS[@]}" diff --staged -U0 2>/dev/null | awk '
  /^\+\+\+ / { file = $0; sub(/^\+\+\+ (b\/)?/, "", file); next }
  /^@@/ { if (match($0, /\+[0-9]+/)) ln = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
  /^\+/ {
    line = substr($0, 2); hit = ""
    base = file; sub(/^.*\//, "", base)
    if (base ~ /^(tsconfig|jsconfig).*\.json$/ && line ~ /"(strict|noImplicitAny|strictNullChecks|strictFunctionTypes|strictBindCallApply|strictPropertyInitialization|noImplicitThis|useUnknownInCatchVariables|alwaysStrict|noUncheckedIndexedAccess|exactOptionalPropertyTypes|noImplicitReturns|noFallthroughCasesInSwitch|noImplicitOverride)"[ \t]*:[ \t]*false/) hit = "a strict flag turned off"
    else if (base ~ /^next\.config\./ && line ~ /(ignoreBuildErrors|ignoreDuringBuilds)[ \t]*:[ \t]*true/) hit = "build errors ignored"
    else if (base ~ /^(mypy\.ini|\.mypy\.ini|setup\.cfg|pyproject\.toml)$/ && line ~ /^[ \t]*ignore_errors[ \t]*=[ \t]*[Tt]rue/) hit = "mypy ignore_errors turned on"
    else if (base ~ /^(pyrightconfig\.json|pyproject\.toml)$/ && line ~ /typeCheckingMode"?[ \t]*[:=][ \t]*"off"/) hit = "pyright turned off"
    if (hit != "" && line !~ /(\/\/|\/\*|#)[ \t]*[^ \t]/ && n < 6) { n++; printf "%s:%d: %s\n", file, ln, hit }
    ln++
  }' || true)
count_exclude() { tr -d '\n\r' | sed -nE 's/.*"exclude"[[:space:]]*:[[:space:]]*\[([^]]*)\].*/\1/p'; }
while IFS= read -r file; do
  case "$file" in tsconfig*.json|*/tsconfig*.json|jsconfig*.json|*/jsconfig*.json) ;; *) continue ;; esac
  git "${GIT_DIR_ARGS[@]}" cat-file -e "HEAD:$file" 2>/dev/null || continue
  WAS=$(git "${GIT_DIR_ARGS[@]}" show "HEAD:$file" 2>/dev/null | count_exclude)
  NOW=$(git "${GIT_DIR_ARGS[@]}" show ":$file" 2>/dev/null | count_exclude)
  case "$NOW" in *//*) continue ;; esac
  WAS_N=$(printf '%s' "$WAS" | tr -cd '"' | wc -c | tr -d '[:space:]')
  NOW_N=$(printf '%s' "$NOW" | tr -cd '"' | wc -c | tr -d '[:space:]')
  if [ "${NOW_N:-0}" -gt "${WAS_N:-0}" ]; then
    LOOSE="${LOOSE:+$LOOSE
}$file: exclude grew from $((WAS_N / 2)) to $((NOW_N / 2)) entries"
  fi
done <<< "$STAGED"

if [ -n "$SUPP" ] || [ -n "$LOOSE" ]; then
  deny "Pre-commit audit DENIED: this commit quiets the checker.

${SUPP}${SUPP:+
}${LOOSE}

Fix what the checker reported. Where the suppression is right, put the reason on that line (or on the comment line above a cast), and the commit goes through. A looser checker config is the user's call: ask them, then write their reason as a comment on the changed line.

ENGINEERING-PRINCIPLES.md section 12 and section 19. Fix, re-stage, commit."
fi

# 1g. The staged source files, through the same parse-level checks the
#     post-edit hook runs. This is the mechanical backstop on agents that
#     never show the model a post-edit hook's output. Prefix the commit
#     with SENIOR_MODE_ALLOW_SYNTAX=1 to pass a finding you can show is wrong.
HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
SYNTAX_NOTE=""
if [ "${SENIOR_MODE_SYNTAX:-on}" != off ] && [ -f "$HOOK_DIR/post-edit-check.sh" ]; then
  case "$CMD" in
    *SENIOR_MODE_ALLOW_SYNTAX=1*) SYNTAX_NOTE=" Code check overridden for this commit (SENIOR_MODE_ALLOW_SYNTAX=1)." ;;
    *)
      CHECK_FILES=()
      while IFS= read -r file; do
        [ -n "$file" ] && [ -f "$REPO/$file" ] || continue
        case "$file" in *.ts|*.tsx|*.mts|*.cts|*.js|*.jsx|*.mjs|*.cjs|*.py|*.pyi|*.go|*.rb|*.sh|*.bash|*.json) ;; *) continue ;; esac
        [ "${#CHECK_FILES[@]}" -lt 40 ] && CHECK_FILES+=("$REPO/$file")
      done <<< "$STAGED"
      if [ "${#CHECK_FILES[@]}" -gt 0 ]; then
        FOUND=$(bash "$HOOK_DIR/post-edit-check.sh" --plain "${CHECK_FILES[@]}" 2>/dev/null | head -n 15 || true)
        if [ -n "$FOUND" ]; then
          deny "Pre-commit audit DENIED: staged files fail the code check.

$FOUND

Fix them, re-stage, commit. If a line is wrong (the import does resolve, the check misread a call), tell the user which one and why, then rerun the commit with SENIOR_MODE_ALLOW_SYNTAX=1 in front of it."
        fi
      fi ;;
  esac
fi

# ── Layer 2: Contextual reminders (pass, with targeted context) ──

MONEY=$(echo "$STAGED" | grep -cE '(billing|payment|payout|invoice|checkout|charge|refund|subscription|commission|ledger|wallet)' || true)
PII=$(echo "$STAGED" | grep -cE '(ssn|pii|bank|encrypt|sensitive|personal|kyc|identity)' || true)
API=$(echo "$STAGED" | grep -cE '(/api/|routes?/|controllers?/|handlers?/|endpoints?/)' || true)
SCHEMA=$(echo "$STAGED" | grep -cE '(schema/|migrations?/|migrate|models?/)' || true)
SERVICE=$(echo "$STAGED" | grep -cE '(services?/|domain/|usecases?/)' || true)

CTX="Pre-commit audit PASSED automated checks.$SYNTAX_NOTE"

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
