#!/usr/bin/env bash
# UserPromptSubmit hook for Claude Code.
# Injects the senior-engineer BEFORE checklist into context every time
# the user submits a prompt.
#
# The failure mode this defends against is the "recitation trap": a rule
# is recalled from memory but not actually applied at the decision
# moment. A hook-injected reminder fires at the decision moment
# regardless of whether the rule was recalled, so the check happens when
# it matters instead of being quoted after the fact.
#
# Also clears the per-session Stop-hook sentinel so senior-check-after.sh
# re-prompts fresh on this turn's end.
#
# Universal: no project-specific content. Edit the additionalContext
# string below to tune the mindset prompt for your project.

set -u

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | tr -d '\n' | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
SENTINEL="${TMPDIR:-/tmp}/claude-senior-stop-${SESSION_ID:-unknown}"
rm -f "$SENTINEL" 2>/dev/null || true

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[SENIOR CHECK | BEFORE] Before responding:\n(1) Is this directive ambiguous in a way that produces different behavior in production? If yes, ASK before coding. A single clarifying question at the start is not an approval loop.\n(2) For non-trivial work, name the 100% version up front so the 80% gap is visible to the user, not hidden in your head.\n(3) Evidence before code: state the diagnosis and what confirms it BEFORE the first edit. Never cite a file, run, or source you have not opened this session.\n(4) The trigger is THIS prompt's arrival, not the moment you remember the rule. Run the checklist now."
  }
}
EOF
