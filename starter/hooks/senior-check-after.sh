#!/usr/bin/env bash
# Stop hook (Claude Code hook contract; wired by every adapter that has a Stop event).
# Two checks on the way out of a turn.
#
# 1. Undone work. Reads the final answer (`last_assistant_message` in the
#    Stop payload) and blocks when it hands back work that wasn't done: a
#    "what I didn't do" list, "I haven't tested", an "Open items" heading.
#    The block says to do the work now, to put the user's decisions to them
#    as a multiple-choice question, and to give human-only steps as
#    instructions. It runs on every turn, push turns included, and blocks at
#    most twice per turn. Code spans and quoted text are stripped first, so
#    an answer that quotes one of these phrases isn't blocked for it. An
#    agent whose Stop payload has no `last_assistant_message` skips this
#    check.
#
# 2. The senior self-audit, once per turn, on turns that did work:
#      first stop of a turn     block with the checklist
#      any later stop           allow
#      the turn pushed          skip. The code already shipped, and a
#                               finding here would start a fix, commit,
#                               push loop.
#      no command, no edit      skip. A question got an answer and there's
#                               nothing to audit. This needs proof that the
#                               session's tool hooks are alive, so an
#                               install that wires only the two senior-check
#                               hooks keeps the check on every turn.
#                               Only shell and edit tools write the marker,
#                               so a turn that only called MCP tools counts
#                               as quiet too.
#                               SENIOR_MODE_AFTER_ALWAYS=1 turns the skip off.
#
# Loop safety: stop_hook_active means the harness is already continuing
# from a Stop block. The self-audit never fires then. The undone-work check
# fires then only while its per-turn count is under 2 and a state file from
# earlier in the session shows the temp dir keeps files for this session
# id. Without that it allows. Worst case is 3 blocks in one turn.
#
# State, per session, in ${TMPDIR:-/tmp}:
#   claude-senior-stop-<id>     the self-audit fired this turn
#   claude-senior-undone-<id>   undone-work blocks this turn (a count)
#   claude-senior-worked-<id>   a shell or edit tool ran this turn
#   claude-senior-tools-<id>    tool hooks have fired in this session
#   claude-push-done-<id>       this turn pushed
# pre-push-checklist.sh and post-edit-format.sh write the worked and tools
# markers. senior-check-before.sh clears the per-turn files when a prompt
# arrives, and every allow below clears them too, which is what agents
# with no prompt event rely on.
#
# Universal: edit the two reason strings to match your project's review
# dimensions. Keep double quotes out of them; the Cursor and Gemini shims
# re-embed the reason in their own JSON.

set -u

INPUT=$(cat)
FLAT=$(printf '%s' "$INPUT" | tr -d '\n\r')
SESSION_ID=$(printf '%s' "$FLAT" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')

T="${TMPDIR:-/tmp}"
ID="${SESSION_ID:-unknown}"
STOPF="$T/claude-senior-stop-$ID"
UNDONEF="$T/claude-senior-undone-$ID"
WORKF="$T/claude-senior-worked-$ID"
TOOLSF="$T/claude-senior-tools-$ID"
PUSHF="$T/claude-push-done-$ID"

ACTIVE=no
re_active='"stop_hook_active"[[:space:]]*:[[:space:]]*true'
[[ "$FLAT" =~ $re_active ]] && ACTIVE=yes

# Every allow ends this hook's part in the turn, so the per-turn state goes
# with it. That includes the push flag: a push made after the self-audit
# block used to leave it behind and switch off the next turn's check.
allow() {
  rm -f "$STOPF" "$UNDONEF" "$WORKF" "$PUSHF" 2>/dev/null || true
  exit 0
}

AFTER='[SENIOR CHECK | AFTER] Before this answer goes out:\n(1) Self-audit the deliverable against ENGINEERING-PRINCIPLES.md: security, data integrity, money and billing paths, auth, PII, the lines-of-code budget.\n(2) Did you ship the 100% version? Anything in scope you can still do, do it now and do not list it. A decision that belongs to the user goes to them as one multiple-choice question (your question tool, recommended option first). A step only a human can take goes to them as exact instructions.\n(3) For every green check you are about to report: what would RED have looked like, and could this run have produced it?\n(4) Would a senior engineer push back on anything here? If yes, fix it now.\n(5) Close non-trivial work with an [AFTER-AUDIT] block. Covered: what this response did and how you verified it. Without senior mode: what this check or the BEFORE check caught that a first pass would have shipped without. Name the catch. Write nothing this turn when the checks changed nothing, and never invent one.\n\nIf the work clears the bar, answer normally. This fires once per turn.'

# ---- 1. undone work ----------------------------------------------------------
MSG=$(printf '%s' "$FLAT" | sed -nE 's/.*"last_assistant_message"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p')

if [ -n "$MSG" ]; then
  # SEP stands in for a line break. It is printable on purpose: bash 3.2
  # (macOS) uses the \001 byte internally and drops it from a regex.
  SEP='%%'
  RSQ=$'\xe2\x80\x99'      # the curly apostrophe, raw
  # Lowercase, straighten apostrophes, turn JSON line breaks into SEP, then
  # drop fenced code, inline code and quoted text. What is left is the
  # answer's own prose, still on one line.
  LC=$(printf '%s' "$MSG" | tr '[:upper:]' '[:lower:]' | sed \
    -e "s/\\\\u2019/'/g" -e "s/${RSQ}/'/g" \
    -e "s/\\\\[nrt]/${SEP}/g" \
    -e 's/```[^`]*```//g' -e 's/`[^`]*`//g' \
    -e 's/\\"[^"\\]*\\"//g')

  B='(^|[^a-z])'
  E='([^a-z]|$)'
  NOT="(haven'?t|have not|didn'?t|did not)"
  re_list="what i ${NOT} (do|done|get to|finish|cover)|what i (left out|left undone|left open|skipped)"
  re_verb="${B}i ${NOT} (yet )?(tried|try|tested|test|looked at|look at|checked|check|verified|verify|built|build|measured|measure|run|ran)${E}"
  re_yet="${B}not done yet${E}|${B}not (yet )?(tried|tested|verified|looked at|checked|run) (with|on|in|against)${E}"
  re_left="${B}(left|leaving) (it |this |that |these |those )?for you${E}|${B}(left|leaving) [a-z ]{0,40}for (later|a follow-?up|next time|another (pass|session|day))${E}"
  re_head="(^|${SEP})[-#>*_ ]*(what'?s (left|open|missing|remaining)|what is (left|open|missing|remaining)|open items?|still open|left open|not done|not covered|remaining( work| items)?|follow-?ups?|future work|deferred( work| items)?|known gaps?)[*_ ]*:?[*_ ]*(${SEP}|\$)"

  HIT=""
  for re in "$re_list" "$re_verb" "$re_yet" "$re_left" "$re_head"; do
    if [[ "$LC" =~ $re ]]; then HIT="${BASH_REMATCH[0]}"; break; fi
  done

  if [ -n "$HIT" ]; then
    n=0
    [ -f "$UNDONEF" ] && read -r n < "$UNDONEF" 2>/dev/null
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    proof=no
    if [ "$ACTIVE" = no ] || [ -f "$STOPF" ] || [ -f "$UNDONEF" ] || [ -f "$TOOLSF" ]; then proof=yes; fi
    if [ "$n" -lt 2 ] && [ "$proof" = yes ]; then
      next=$((n + 1))
      printf '%s\n' "$next" > "$UNDONEF" 2>/dev/null
      back=""
      [ -f "$UNDONEF" ] && read -r back < "$UNDONEF" 2>/dev/null
      # Block only when the count stuck. A temp dir that drops it would
      # let this fire forever.
      if [ "$back" = "$next" ]; then
        # The hit goes back inside a JSON string: keep letters, digits,
        # spaces, apostrophes and hyphens, nothing else.
        QUOTE=$(printf '%s' "$HIT" | tr -cd "a-z0-9 '-")
        QUOTE=${QUOTE# }; QUOTE=${QUOTE% }
        REASON="[SENIOR CHECK | UNDONE WORK] Your answer hands back work you did not do ('${QUOTE}'). Do it now, in this turn, then answer. If a piece is the user's decision, ask it as one multiple-choice question (your question tool, recommended option first) before you finish. If a step can only be done by a human (typing a secret, pressing a button only their account has), give the exact steps as an instruction. If something failed or is blocked, report that as a result, with the error. Never claim work that did not happen, and never drop the item to make the answer look finished."
        # First stop of a turn that did not push: fold the self-audit in,
        # so the turn costs one extra round and not two.
        if [ "$ACTIVE" = no ] && [ ! -f "$STOPF" ] && [ ! -f "$PUSHF" ]; then
          touch "$STOPF" 2>/dev/null || true
          REASON="${REASON}\\n\\n${AFTER}"
        fi
        printf '{\n  "decision": "block",\n  "reason": "%s"\n}\n' "$REASON"
        exit 0
      fi
    fi
  fi
fi

# ---- 2. the senior self-audit, once per turn ---------------------------------
[ "$ACTIVE" = yes ] && allow
[ -f "$PUSHF" ] && allow
[ -f "$STOPF" ] && allow
if [ "${SENIOR_MODE_AFTER_ALWAYS:-}" != 1 ] && [ -f "$TOOLSF" ] && [ ! -f "$WORKF" ]; then
  allow
fi

touch "$STOPF" 2>/dev/null || true
printf '{\n  "decision": "block",\n  "reason": "%s"\n}\n' "$AFTER"
