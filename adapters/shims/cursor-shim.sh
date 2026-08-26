#!/usr/bin/env bash
# Cursor hook shim: translates Cursor's hooks.json payloads to and from the
# canonical senior-mode hook contract (the Claude Code / Codex / Copilot JSON
# shape every script in .senior-mode/hooks/ speaks).
#
#   cursor-shim.sh shell   <hook.sh>...   beforeShellExecution -> PreToolUse(Bash)
#   cursor-shim.sh edit    <hook.sh>      afterFileEdit        -> PostToolUse(Write)
#   cursor-shim.sh session <hook.sh> [args]  sessionStart      -> SessionStart (+ context)
#   cursor-shim.sh prompt  <hook.sh>...   beforeSubmitPrompt   -> UserPromptSubmit (touch/advise; cannot inject)
#   cursor-shim.sh stop    <hook.sh>      stop                 -> Stop (block -> followup_message;
#                                         loop_count > 0 maps to stop_hook_active so the
#                                         canonical backstop caps the loop, not loop_limit)
#
# Cursor stdin (documented): beforeShellExecution {command, cwd, conversation_id,
# hook_event_name, workspace_roots[]}; afterFileEdit {file_path, edits[]};
# sessionStart {session_id, ...}; beforeSubmitPrompt {prompt}; stop {status, loop_count}.
# Cursor stdout: shell -> {permission: allow|deny|ask, user_message, agent_message};
# session -> {additional_context}; prompt -> {continue: bool, user_message};
# stop -> {followup_message}. Exit 0 always (fail-open); Cursor treats exit 2 as block.
#
# Cursor exports CLAUDE_PROJECT_DIR as an alias of CURSOR_PROJECT_DIR, so the
# canonical hooks find the repo the same way they do under Claude Code.

set -u
MODE="${1:-}"; shift || true
INPUT=$(cat)

# ---- tiny JSON field readers (string values, no nesting assumptions) --------
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
json_num() { # json_num <json> <key> -> bare numeric value (or empty), portable
  printf '%s' "$1" | tr -d '\n' | awk -v k="$2" '{
    s = $0; pat = "\"" k "\"[[:space:]]*:[[:space:]]*";
    if (match(s, pat)) {
      s = substr(s, RSTART + RLENGTH);
      if (match(s, /^-?[0-9]+/)) print substr(s, RSTART, RLENGTH)
    }
  }'
}
jget() { json_field "$INPUT" "$1"; }
jesc() { local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}; printf '%s' "$s"; }
# value already JSON-escaped from the source payload: keep as-is when re-embedding
SESSION=$(jget conversation_id); [ -n "$SESSION" ] || SESSION=$(jget session_id); [ -n "$SESSION" ] || SESSION=cursor
CWD=$(jget cwd)

run_hook() { # run_hook <hook.sh> [args] <<< canonical-json  -> stdout of the hook
  local h="$1"; shift
  printf '%s' "$CANON" | bash "$h" "$@" 2>/dev/null || true
}
field_of() { json_field "$1" "$2"; }

case "$MODE" in
  shell)
    CMD=$(jget command)
    CANON=$(printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"}}' "$SESSION" "$CWD" "$CMD")
    CTX=""
    for h in "$@"; do
      OUT=$(run_hook "$h")
      if printf '%s' "$OUT" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        R=$(field_of "$OUT" permissionDecisionReason)
        printf '{"permission":"deny","user_message":"%s","agent_message":"%s"}\n' "$R" "$R"
        exit 0
      fi
      C=$(field_of "$OUT" additionalContext); [ -n "$C" ] && CTX="${CTX:+$CTX\\n\\n}$C"
    done
    if [ -n "$CTX" ]; then printf '{"permission":"allow","agent_message":"%s"}\n' "$CTX"; else printf '{"permission":"allow"}\n'; fi
    ;;
  edit)
    FP=$(jget file_path)
    CANON=$(printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$SESSION" "$FP")
    for h in "$@"; do run_hook "$h" >/dev/null; done
    printf '{}\n'
    ;;
  session)
    CANON=$(printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"startup","cwd":"%s"}' "$SESSION" "$CWD")
    CTX=""
    # every hook gets the same payload; collect their additionalContext
    while [ $# -gt 0 ]; do
      h="$1"; shift; args=""
      # allow "script.sh:arg" to pass one argument (e.g. session-registry.sh:register)
      case "$h" in *:*) args=${h#*:}; h=${h%%:*};; esac
      OUT=$(run_hook "$h" $args)
      C=$(field_of "$OUT" additionalContext); [ -n "$C" ] && CTX="${CTX:+$CTX\\n\\n}$C"
    done
    if [ -n "$CTX" ]; then printf '{"additional_context":"%s"}\n' "$CTX"; else printf '{}\n'; fi
    ;;
  prompt)
    P=$(jget prompt)
    CANON=$(printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"%s","cwd":"%s"}' "$SESSION" "$P" "$CWD")
    while [ $# -gt 0 ]; do
      h="$1"; shift; args=""; case "$h" in *:*) args=${h#*:}; h=${h%%:*};; esac
      run_hook "$h" $args >/dev/null
    done
    printf '{"continue":true}\n'   # Cursor cannot inject context here; the checklist arrives via sessionStart
    ;;
  stop)
    # Cursor's loop_count counts the stop hook's own auto follow-ups; nonzero
    # means the model is already continuing because of us, which is exactly
    # what stop_hook_active means in the canonical contract. Mapping it lets
    # senior-check-after.sh's own backstop end the loop (at most one follow-up
    # per block), instead of a hooks.json loop_limit that Cursor counts per
    # conversation rather than per turn. A non-numeric value maps to false,
    # which only ever risks one extra follow-up, never a runaway.
    LOOPS=$(json_num "$INPUT" loop_count); [ -n "$LOOPS" ] || LOOPS=0
    ACTIVE=false; [ "$LOOPS" -gt 0 ] 2>/dev/null && ACTIVE=true
    CANON=$(printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":%s}' "$SESSION" "$ACTIVE")
    OUT=$(run_hook "$1")
    if printf '%s' "$OUT" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
      R=$(field_of "$OUT" reason)
      printf '{"followup_message":"%s"}\n' "$R"
    else
      printf '{}\n'
    fi
    ;;
  *)
    printf '{}\n' ;;
esac
exit 0
