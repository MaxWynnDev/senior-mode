#!/usr/bin/env bash
# Gemini CLI hook shim. Gemini's stdin is already the canonical shape
# (session_id, cwd, hook_event_name, tool_name, tool_input, prompt); only the
# event names and the stdout contract differ:
#
#   Gemini event     canonical event     Gemini expects on stdout
#   BeforeTool       PreToolUse          {"decision":"deny","reason":...}  (allow = {} )
#   AfterTool        PostToolUse         {}
#   BeforeAgent      UserPromptSubmit    {"hookSpecificOutput":{"hookEventName":"BeforeAgent","additionalContext":...}}
#   SessionStart     SessionStart        same additionalContext shape, hookEventName SessionStart
#   SessionEnd       SessionEnd          {}
#   AfterAgent       Stop                {"decision":"deny","reason":...} rejects the response and
#                                        re-prompts with the reason (allow = {}). AfterAgent stdin
#                                        carries stop_hook_active, which the Stop hook honors, so
#                                        the deny fires once and the retry passes.
#
#   gemini-shim.sh <GeminiEvent> <hook.sh[:arg]>...
#
# Gemini's shell tool is run_shell_command with tool_input.command; its edit
# tools (write_file, replace) carry tool_input.file_path. The canonical hooks
# read exactly those keys. Gemini exports CLAUDE_PROJECT_DIR as an alias.
# Exit 0 always (fail-open); Gemini treats exit 2 as a hard block.

set -u
EVENT="${1:-}"; shift || true
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
field_of() { json_field "$1" "$2"; }

# rewrite hook_event_name to the canonical one so hooks that check it behave
case "$EVENT" in
  BeforeTool)   CANON_EV=PreToolUse ;;
  AfterTool)    CANON_EV=PostToolUse ;;
  BeforeAgent)  CANON_EV=UserPromptSubmit ;;
  SessionStart) CANON_EV=SessionStart ;;
  SessionEnd)   CANON_EV=SessionEnd ;;
  AfterAgent)   CANON_EV=Stop ;;
  *)            CANON_EV=$EVENT ;;
esac
CANON=$(printf '%s' "$INPUT" | sed "s/\"hook_event_name\"[[:space:]]*:[[:space:]]*\"[A-Za-z]*\"/\"hook_event_name\": \"$CANON_EV\"/")
# Gemini's shell tool name -> the matcher the hooks expect
CANON=$(printf '%s' "$CANON" | sed 's/"tool_name"[[:space:]]*:[[:space:]]*"run_shell_command"/"tool_name": "Bash"/; s/"tool_name"[[:space:]]*:[[:space:]]*"write_file"/"tool_name": "Write"/; s/"tool_name"[[:space:]]*:[[:space:]]*"replace"/"tool_name": "Edit"/')

CTX=""
while [ $# -gt 0 ]; do
  h="$1"; shift; args=""; case "$h" in *:*) args=${h#*:}; h=${h%%:*};; esac
  OUT=$(printf '%s' "$CANON" | bash "$h" $args 2>/dev/null || true)
  case "$EVENT" in
    BeforeTool)
      if printf '%s' "$OUT" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        R=$(field_of "$OUT" permissionDecisionReason)
        printf '{"decision":"deny","reason":"%s","systemMessage":"%s"}\n' "$R" "$R"
        exit 0
      fi ;;
    AfterAgent)
      # AfterAgent deny rejects the response and re-prompts the model with the
      # reason, the same enforcement Stop gives Claude Code. The passthrough
      # payload keeps stop_hook_active, so the hook's own backstop ends the
      # loop after one deny.
      if printf '%s' "$OUT" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
        R=$(field_of "$OUT" reason)
        printf '{"decision":"deny","reason":"%s"}\n' "$R"
        exit 0
      fi ;;
  esac
  C=$(field_of "$OUT" additionalContext); [ -n "$C" ] && CTX="${CTX:+$CTX\\n\\n}$C"
done

case "$EVENT" in
  BeforeAgent|SessionStart)
    if [ -n "$CTX" ]; then
      printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$EVENT" "$CTX"
    else
      printf '{}\n'
    fi ;;
  *) printf '{}\n' ;;
esac
exit 0
