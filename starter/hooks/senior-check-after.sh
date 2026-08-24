#!/usr/bin/env bash
# Stop hook for Claude Code.
# Injects a senior self-audit reminder once per turn, focused on work
# quality before the response is finalized.
#
# Loop prevention via per-session sentinel:
#   first stop in a turn  -> block + inject audit reminder
#   second stop           -> allow through
# The UserPromptSubmit hook clears the sentinel each new turn.
#
# Push-turn skip (optional): if a pre-push hook sets the SESSION-SCOPED push
# sentinel (meaning this turn already pushed), skip the after-check. The
# code is already shipped; a post-push audit finding would create a
# fix-forward commit + push loop. The gate belongs BEFORE commit and
# push, not after. (The sentinel is keyed by session_id so concurrent
# Claude Code sessions on the same machine cannot clear each other's
# flags.)
#
# Universal: edit the reason string to match your project's review
# dimensions (the example below uses generic high-stakes categories).

set -u

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | tr -d '\n' | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
SENTINEL="${TMPDIR:-/tmp}/claude-senior-stop-${SESSION_ID:-unknown}"
PUSH_DONE="${TMPDIR:-/tmp}/claude-push-done-${SESSION_ID:-unknown}"

# Hard loop backstop (canonical). When the harness is already continuing
# because a prior Stop-hook block fired, stop_hook_active is true in the
# input. Honor it unconditionally so this hook can NEVER run away to the
# consecutive-block cap, even if the temp sentinel below fails to persist
# (unwritable TMPDIR, rotating/empty session_id, cleared file). This is the
# robust guard the sentinel only approximates.
if printf '%s' "$INPUT" | tr -d '\n' | grep -qE '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  rm -f "$SENTINEL" 2>/dev/null || true
  exit 0
fi

# Skip after-check on turns that pushed
if [ -f "$PUSH_DONE" ]; then
  rm -f "$PUSH_DONE" 2>/dev/null || true
  rm -f "$SENTINEL" 2>/dev/null || true
  exit 0
fi

# Second stop this turn: the model already saw the checklist. Allow.
if [ -f "$SENTINEL" ]; then
  rm -f "$SENTINEL" 2>/dev/null || true
  exit 0
fi

# First stop: block and inject the audit reminder
touch "$SENTINEL" 2>/dev/null || true

cat <<'EOF'
{
  "decision": "block",
  "reason": "[SENIOR CHECK | AFTER] Before finalizing this response:\n(1) Did you self-audit this deliverable against ENGINEERING-PRINCIPLES.md (senior-mode)? Security, data integrity, money/billing paths, auth, PII, lines-of-code budget.\n(2) Did you ship the 100% version or cut corners? Name any gaps explicitly so the user sees them.\n(3) For every green check you are about to report: what would RED have looked like, and could this run have produced it? A detector that cannot fail proves nothing.\n(4) Would a senior engineer push back on anything here? If yes, fix it now.\n\nIf the work clears the bar, respond normally. This fires once per turn."
}
EOF
