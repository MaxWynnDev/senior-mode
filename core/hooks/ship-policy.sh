#!/usr/bin/env bash
# UserPromptSubmit: standing ship-loop policy reminder (one line).
#
# OPTIONAL: wire this in settings.json only if the project adopts the
# ship-loop-by-default policy (see WORKFLOW.md "The ship loop" and
# .senior-mode/commands/ship.md). It keeps the policy in front of every prompt
# so a session does not "helpfully" push a behavior change straight to the
# deploy branch. Costs one short line of context per turn.
#
# Edit the sentence to match the loop your project actually runs (with or
# without a staging leg).

cat >/dev/null
cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[SHIP POLICY] Behavior-changing updates ship through the /ship loop (audit, commit, push, watch CI to a green conclusion, watch the deploy, then post-deploy checks), never a bare push. Exceptions: docs/comments-only diffs, emergency rollbacks, or the user saying 'quick push'."
  }
}
EOF
exit 0
