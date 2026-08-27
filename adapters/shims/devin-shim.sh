#!/usr/bin/env bash
# Devin CLI hook shim. Devin's stdin is already the canonical shape
# (session_id, hook_event_name, tool_name, tool_input.command), and its
# UserPromptSubmit, SessionStart and PostToolUse honor the canonical
# hookSpecificOutput.additionalContext, so those hooks run unshimmed. What
# Devin does NOT read is hookSpecificOutput.permissionDecision: a PreToolUse
# hook approves or blocks with a TOP-LEVEL {"decision":"block","reason":...}
# (or exit code 2). The senior-mode guards emit the nested Claude shape, so
# without translation every deny reads as allow.
#
#   devin-shim.sh guard <hook.sh>...   PreToolUse: nested deny -> top-level block
#
# A guard's allow-side additionalContext is dropped: Devin documents
# additionalContext for UserPromptSubmit, SessionStart and PostToolUse only.
# Exit 0 always (fail-open); Devin treats exit 2 as a hard block.

set -u
MODE="${1:-}"; shift || true
INPUT=$(cat)

json_field() { # json_field <json> <key> -> raw (still-escaped) string value, portable (no GNU sed extensions)
  printf '%s' "$1" | tr -d '\n' | awk -v k="$2" '{
    s = $0; pat = "\"" k "\"[[:space:]]*:[[:space:]]*\"";
    if (match(s, pat)) {
      s = substr(s, RSTART + RLENGTH); out = "";
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1);
        if (c == "\\") { out = out c substr(s, i + 1, 1); i++; continue }
        if (c == "\"") break;
        out = out c
      }
      print out
    }
  }'
}

case "$MODE" in
  guard)
    for h in "$@"; do
      OUT=$(printf '%s' "$INPUT" | bash "$h" 2>/dev/null || true)
      if printf '%s' "$OUT" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        R=$(json_field "$OUT" permissionDecisionReason)
        printf '{"decision":"block","reason":"%s"}\n' "$R"
        exit 0
      fi
    done
    printf '{}\n'
    ;;
  *) printf '{}\n' ;;
esac
exit 0
