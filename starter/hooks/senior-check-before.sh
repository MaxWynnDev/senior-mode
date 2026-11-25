#!/usr/bin/env bash
# UserPromptSubmit hook (Claude Code hook contract; wired by every adapter that has a prompt event).
# Injects the senior-engineer BEFORE checklist into context every time
# the user submits a prompt.
#
# The failure mode this defends against is the "recitation trap": a rule
# is recalled from memory but not actually applied at the decision
# moment. A hook-injected reminder fires at the decision moment
# regardless of whether the rule was recalled, so the check happens when
# it matters instead of being quoted after the fact.
#
# Also clears the per-turn state senior-check-after.sh keeps (the stop
# sentinel, the undone-work count, the worked marker, the push flag, the
# list of edited source files), so the Stop hook starts this turn fresh.
#
# A background-task notification is not a prompt from the user. Claude
# Code runs prompt hooks for those too, with the notification as the
# prompt text. This hook stays silent for them and leaves the turn state
# alone: the work the notification reports on belongs to the turn that
# started it, and the checklist is already in context.
#
# Universal: no project-specific content. Edit the additionalContext
# string below to tune the mindset prompt for your project.

set -u

INPUT=$(cat)
FLAT=$(printf '%s' "$INPUT" | tr -d '\n\r')

re_note='"prompt"[[:space:]]*:[[:space:]]*"(\\n|[[:space:]])*<task-notification>'
if [[ "$FLAT" =~ $re_note ]]; then
  printf '{}\n'
  exit 0
fi

SESSION_ID=$(printf '%s' "$FLAT" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
T="${TMPDIR:-/tmp}"
ID="${SESSION_ID:-unknown}"
rm -f "$T/claude-senior-stop-$ID" "$T/claude-senior-undone-$ID" \
      "$T/claude-senior-worked-$ID" "$T/claude-push-done-$ID" \
      "$T/claude-senior-edited-$ID" 2>/dev/null || true

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[SENIOR CHECK | BEFORE] Before responding:\n(1) Is this directive ambiguous in a way that produces different behavior in production? If yes, ASK before coding, with your question tool when you have one. A single clarifying question at the start is not an approval loop.\n(2) For non-trivial work, name the 100% version up front. That is what ships. Name the shortcut an 80% pass would take, so you can refuse it.\n(3) Evidence before code: state the diagnosis and what confirms it BEFORE the first edit. Never cite a file, run, or source you have not opened this session.\n(4) Finish in this turn. The answer says what you covered. It never lists what you left.\n(5) The trigger is THIS prompt's arrival, not the moment you remember the rule. Run the checklist now."
  }
}
EOF
