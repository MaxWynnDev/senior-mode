#!/usr/bin/env bash
# UserPromptSubmit hook: the stakes advisor (Claude Code hook contract).
#
# Fires when a prompt arrives (same moment as senior-check-before) and
# scans two signals for high-stakes surface:
#   1. The user's prompt text, matched case-insensitively. The raw hook
#      payload also carries metadata keys (session_id, transcript_path,
#      cwd, hook_event_name) whose names and values collide with this
#      vocabulary, so the prompt value is extracted and only that is
#      matched.
#   2. The file paths in the working and staged diff, minus the agent
#      config trees (`.claude/`, `.senior-mode/`, ...). Editing
#      `session-registry.sh` is not auth work.
# On a match it names the reviewer that covers the surface (money, auth,
# PII, migrations) and tells the agent to run it before the change ships.
# On no match it prints an empty object.
#
# It does not start a multi-agent workflow and does not tell the agent to.
# Claude Code runs a workflow only when the user asks for one ("ultracode",
# "use a workflow"), so the message says a workflow is the user's call.
# The file keeps its old name so existing wiring keeps working.
#
# The keyword patterns use explicit non-letter boundaries, not substrings.
# The substring versions fired on "session" (auth), "author" (auth),
# "className" (it contains "ssn"), "git checkout" (money), "open tests"
# (it contains "pen tests") and "dependency injection" (security).
#
# A background-task notification is not a prompt from the user, so the
# hook stays silent for those.
#
# Matched categories and reviewer names come from fixed lists, so
# interpolating them into the JSON below carries no escaping risk.
#
# UNIVERSAL: the vocabulary below is a generic high-stakes set. Tune the
# patterns to your project's hot spots.

set -u

INPUT=$(cat)

# Match the PROMPT TEXT ONLY (allowlist), never the surrounding payload
# metadata. The prompt has shipped under the key "prompt"; newer payload
# documentation also names "user_input". Try both, then fall back to
# scrubbing the known metadata pairs so we still match the prompt but not
# the metadata. Allowlist-first means a NEW metadata field added by a
# future Claude Code version cannot reintroduce the false-positive.
PROMPT=$(printf '%s' "$INPUT" | sed -nE 's/.*"prompt"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p')
if [ -z "$PROMPT" ]; then
  PROMPT=$(printf '%s' "$INPUT" | sed -nE 's/.*"user_input"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p')
fi
if [ -z "$PROMPT" ]; then
  PROMPT=$(printf '%s' "$INPUT" | sed -E 's/"(session_id|prompt_id|transcript_path|cwd|hook_event_name|permission_mode)"[[:space:]]*:[[:space:]]*"[^"]*"//g')
fi
case "$PROMPT" in
  '<task-notification>'*|'\n<task-notification>'*) printf '{}\n'; exit 0 ;;
esac
LC_INPUT=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')

# Changed file paths (working tree + staged), lowercased, minus the
# `.claude/` tree. Best-effort: if not a repo or git is unavailable, this
# is empty and only the prompt-text signals fire.
PROJECT_DIR="${SENIOR_MODE_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-${CURSOR_PROJECT_DIR:-${GEMINI_PROJECT_DIR:-.}}}}"
CHANGED=$( { git -C "$PROJECT_DIR" diff --name-only HEAD 2>/dev/null; \
            git -C "$PROJECT_DIR" diff --name-only --cached 2>/dev/null; } | grep -vE '(^|/)(\.claude|\.senior-mode|\.codex|\.cursor|\.gemini|\.opencode|\.factory|\.devin|\.augment|\.agents)/' || true )
LC_CHANGED=$(printf '%s' "$CHANGED" | tr '[:upper:]' '[:lower:]')

HITS=""
add_hit() { case " $HITS " in *" $1 "*) ;; *) HITS="$HITS $1" ;; esac; }

# --- Path signals on the working/staged diff (segment-anchored) --------
printf '%s' "$LC_CHANGED" | grep -qE '(^|/)(billing|payments?|payouts?|invoices?|checkout|subscriptions?|commissions?|ledger)(/|\.|-|_)' && add_hit money
printf '%s' "$LC_CHANGED" | grep -qE '(^|/)(migrations?|schema)(/|\.|-|_)|migrate'                                             && add_hit migration
printf '%s' "$LC_CHANGED" | grep -qE '(^|/)(auth|sessions?|permissions?|rbac|acl|tenancy)(/|\.|-|_)'                          && add_hit auth

# --- Keyword signals on the prompt text --------------------------------
# B and E are a non-letter (or the edge of the text) on each side.
B='(^|[^a-z])'
E='([^a-z]|$)'
printf '%s' "$LC_INPUT" | grep -qE "payment|payout|billing|invoice|refund|chargeback|subscription|commission|ledger|checkout (page|flow|session|form|cart)|${B}charg(e|es|ed|ing) (the |a |an |each |every |their )?(card|customer|client|user|account|merchant|fee)" && add_hit money
printf '%s' "$LC_INPUT" | grep -qE 'migrat|alter table|schema change|drop column|drop table' && add_hit migration
printf '%s' "$LC_INPUT" | grep -qE "${B}(auth|authn|authz|oauth|sso|rbac|acl)${E}|authenticat|authoriz|login|log in|sign-?in|permission|access control|multi-tenant|tenant isol|api key|session (token|cookie|store|secret|expiry|fixation|hijack)" && add_hit auth
printf '%s' "$LC_INPUT" | grep -qE "${B}(ssn|pii|gdpr|hipaa)${E}|personal data|encrypt|sensitive (data|attribute)" && add_hit pii
printf '%s' "$LC_INPUT" | grep -qE "security review|security audit|${B}pen.?test|${B}vuln|exploit|(sql|prompt|command|code|html|script) injection|${B}(xss|csrf|ssrf)${E}" && add_hit audit
printf '%s' "$LC_INPUT" | grep -qE 'cross-cutting|large refactor|big refactor|re-?architect|rewrite the (whole|entire|service|module|app|backend|frontend)|migrate the (whole|entire|codebase|app|service)' && add_hit refactor

if [ -z "$HITS" ]; then
  printf '{}\n'
  exit 0
fi

HITS_TRIM=$(printf '%s' "$HITS" | sed -E 's/^ +//')

# Which review covers each category. A broad audit or a large refactor has
# no single reviewer, so those get the pre-push fan-out.
REVIEWS=""
add_review() { case ", $REVIEWS, " in *", $1, "*) ;; *) REVIEWS="${REVIEWS:+$REVIEWS, }$1" ;; esac; }
for h in $HITS_TRIM; do
  case "$h" in
    money)     add_review money-path-reviewer ;;
    migration) add_review migration-reviewer ;;
    auth|pii)  add_review tenant-isolation-reviewer ;;
    *)         add_review "the pre-push fan-out" ;;
  esac
done

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[ULTRACODE ADVISOR] This turn touches high-stakes surface (matched: ${HITS_TRIM}). Before any of it ships, run the matching review on the diff: ${REVIEWS}. Use the reviewer subagents where the agent has them, or work through the senior-mode reviewer briefs as checklists where it does not. A multi-agent workflow is the user's call: start one only if they asked for it (ultracode, use a workflow), otherwise offer it in one line. Advisory: skip this for a question or a read-only task."
  }
}
EOF
