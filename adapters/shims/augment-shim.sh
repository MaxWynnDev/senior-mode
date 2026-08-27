#!/usr/bin/env bash
# Augment (Auggie) hook shim. Augment's config format is the canonical one,
# but four things differ, all documented:
#   - stdin names the session conversation_id; the hooks read session_id
#   - a PreToolUse deny is the canonical nested shape (pass through), and
#     only "deny" is implemented on Augment's side
#   - the Stop output nests decision/reason INSIDE hookSpecificOutput, the
#     inverse of the canonical top level; there is no stop_hook_active, so
#     the sentinel in senior-check-after.sh is the loop cap
#   - edits arrive as save-file / str-replace-editor with the file under
#     tool_input.path, so the format mode maps them to Write / Edit and
#     file_path before the formatter reads the payload
# There is no UserPromptSubmit event; the BEFORE checklist arrives once per
# session via SessionStart, which Augment documents for additionalContext.
#
#   augment-shim.sh guard         <hook.sh>...     PreToolUse
#   augment-shim.sh format        <hook.sh>        PostToolUse
#   augment-shim.sh session-start <hook.sh[:arg]>...  SessionStart (+ context)
#   augment-shim.sh session-end   <hook.sh[:arg]>...  SessionEnd
#   augment-shim.sh stop          <hook.sh>        Stop (block -> nested shape)
#
# Exit 0 always (fail-open); Augment treats exit 2 as a hard block.

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
field_of() { json_field "$1" "$2"; }

# The hooks key their sentinels and registry entries on session_id. Prepend
# one mapped from conversation_id (the value is already JSON-escaped in the
# source payload, so it re-embeds as-is).
SID=$(json_field "$INPUT" conversation_id)
[ -n "$SID" ] || SID=$(json_field "$INPUT" session_id)
[ -n "$SID" ] || SID=augment
CANON="{\"session_id\":\"$SID\",${INPUT#*\{}"

run_hook() { # run_hook <hook.sh> [args] <<< canonical-json -> stdout of the hook
  local h="$1"; shift
  printf '%s' "$CANON" | bash "$h" "$@" 2>/dev/null || true
}

case "$MODE" in
  guard)
    for h in "$@"; do
      OUT=$(run_hook "$h")
      if printf '%s' "$OUT" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        # already Augment's documented deny shape; pass it through whole
        printf '%s\n' "$OUT"
        exit 0
      fi
    done
    printf '{}\n'
    ;;
  format)
    # save-file -> Write, str-replace-editor -> Edit, path -> file_path.
    # Only raw keys match: escaped quotes inside embedded content cannot.
    CANON=$(printf '%s' "$CANON" | sed 's/"tool_name"[[:space:]]*:[[:space:]]*"save-file"/"tool_name": "Write"/; s/"tool_name"[[:space:]]*:[[:space:]]*"str-replace-editor"/"tool_name": "Edit"/; s/"path"[[:space:]]*:/"file_path":/g')
    for h in "$@"; do run_hook "$h" >/dev/null; done
    printf '{}\n'
    ;;
  session-start)
    CTX=""
    while [ $# -gt 0 ]; do
      h="$1"; shift; args=""
      case "$h" in *:*) args=${h#*:}; h=${h%%:*};; esac
      OUT=$(run_hook "$h" $args)
      C=$(field_of "$OUT" additionalContext); [ -n "$C" ] && CTX="${CTX:+$CTX\\n\\n}$C"
    done
    if [ -n "$CTX" ]; then
      printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$CTX"
    else
      printf '{}\n'
    fi
    ;;
  session-end)
    while [ $# -gt 0 ]; do
      h="$1"; shift; args=""
      case "$h" in *:*) args=${h#*:}; h=${h%%:*};; esac
      run_hook "$h" $args >/dev/null
    done
    printf '{}\n'
    ;;
  stop)
    OUT=$(run_hook "$1")
    if printf '%s' "$OUT" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
      R=$(field_of "$OUT" reason)
      printf '{"hookSpecificOutput":{"hookEventName":"Stop","decision":"block","reason":"%s"}}\n' "$R"
    else
      printf '{}\n'
    fi
    ;;
  *) printf '{}\n' ;;
esac
exit 0
