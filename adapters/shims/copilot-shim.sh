#!/usr/bin/env bash
# GitHub Copilot hook shim. With PascalCase event names Copilot delivers the
# "VS Code compatible" payload format, which IS the canonical hook contract
# (snake_case fields, Claude tool names), so the scripts read their stdin
# unchanged. What Copilot does NOT read is the nested
# hookSpecificOutput.permissionDecision: its documented preToolUse decision
# control is TOP-LEVEL permissionDecision / permissionDecisionReason
# (hookSpecificOutput appears nowhere in the hooks reference). Without
# translation every guard deny reads as allow.
#
#   copilot-shim.sh guard <hook.sh>...   PreToolUse: nested deny -> top-level
#
# Copilot's preToolUse command hooks are fail-closed on a non-zero exit, so
# this shim exits 0 on every path; a broken guard allows rather than blocks
# (timeouts are fail-open on Copilot's side already).

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
        printf '{"permissionDecision":"deny","permissionDecisionReason":"%s"}\n' "$R"
        exit 0
      fi
    done
    printf '{}\n'
    ;;
  *) printf '{}\n' ;;
esac
exit 0
