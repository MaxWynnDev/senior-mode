#!/usr/bin/env bash
# UserPromptSubmit hook: the ultracode advisor (Claude Code hook contract).
#
# Implements the "ultracode when necessary" half of the operating
# posture documented in CLAUDE.md (## Operating posture). The "max
# always" half lives in CLAUDE.md only: a per-turn token ceiling is a
# user-input lever ("+<N>k") that a hook cannot reliably set, so it is
# encoded as a standing instruction rather than injected here.
#
# This hook fires at prompt-arrival (same moment as senior-check-before)
# and scans two signals for high-stakes surface:
#   1. The user's prompt text (matched case-insensitively). The raw hook
#      payload also carries metadata keys (session_id, transcript_path,
#      cwd, hook_event_name) whose names/values WOULD collide with this
#      vocabulary ("session_id" contains "session"; cwd may contain path
#      words like "payments"). So we extract the prompt value and match
#      only that.
#   2. The current working + staged diff file paths, EXCLUDING the
#      agent config trees (`.claude/`, `.senior-mode/`, ...): editing `session-registry.sh` is not auth work,
#      and without the exclusion every hook edit tripped the "auth"
#      signal.
# On a match it injects an advisory nudge to prefer a multi-agent
# Workflow (parallel finders + adversarial verification + synthesis)
# over a single-context pass. On no match it emits an empty object and
# stays silent. The point is calibration, not nagging: a flagged task
# that is genuinely trivial may still proceed solo.
#
# Matched categories are drawn from a fixed vocabulary, so interpolating
# them into the JSON below carries no escaping risk.
#
# UNIVERSAL: the signal vocabulary below is a generic high-stakes set
# (money/billing, auth/access, migrations/schema, security, PII,
# large refactors). Tune the grep patterns to your project's hot spots.

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
printf '%s' "$LC_INPUT" | grep -qE 'payment|payout|billing|invoice|checkout|charge|refund|subscription|commission|ledger' && add_hit money
printf '%s' "$LC_INPUT" | grep -qE 'migrat|alter table|schema change|drop column|drop table'                             && add_hit migration
printf '%s' "$LC_INPUT" | grep -qE 'auth|login|session|permission|rbac|access control|multi-tenant|tenant isol'          && add_hit auth
printf '%s' "$LC_INPUT" | grep -qE 'ssn|\bpii\b|personal data|encrypt|sensitive (data|attribute)|gdpr|hipaa'             && add_hit pii
printf '%s' "$LC_INPUT" | grep -qE 'security review|security audit|pen.?test|\bvuln|exploit|injection'                   && add_hit audit
printf '%s' "$LC_INPUT" | grep -qE 'cross-cutting|architecture|large refactor|rewrite the|migrate the'                  && add_hit refactor

if [ -z "$HITS" ]; then
  printf '{}\n'
  exit 0
fi

HITS_TRIM=$(printf '%s' "$HITS" | sed -E 's/^ +//')

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[ULTRACODE ADVISOR] This turn touches high-stakes surface (matched: ${HITS_TRIM}). Per CLAUDE.md operating posture this is an 'ultracode when necessary' trigger: prefer a multi-agent Workflow (parallel finders + adversarial verification + synthesis) over a single-context pass, and do not hold tokens back. Advisory, not a mandate: if on reflection the task is genuinely trivial or read-only, proceed solo and say why in one line."
  }
}
EOF
