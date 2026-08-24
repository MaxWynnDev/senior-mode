#!/usr/bin/env bash
# Tangle guard for coding agents (Claude Code hook contract). Wired on PreToolUse / Bash.
#
# Blocks the ONE action that tangles a shared working tree: a tree- or
# history-mutating git command (commit, push, merge, rebase, pull,
# cherry-pick, revert, am, reset --hard, stash pop/apply, apply) run from
# a checkout that ANOTHER live session is also sitting in, by a session
# that is NOT the incumbent (earliest) one in that checkout.
#
# It does NOT block:
#   - any non-git command (fast string exit, no git calls)
#   - read-only git (status, log, diff, fetch, worktree, ...)
#   - the incumbent session (it owns the checkout, commits normally)
#   - a solo session (no other live session shares the tree)
#   - a session already inside its own linked worktree (the safe path)
#   - a command that opts out with CLAUDE_ALLOW_SHARED_GIT=1
#
# So the daily flow is unchanged: alone, or as the main-line session, you
# push exactly as before. The block only fires for a LATER session that
# stayed in the shared checkout instead of running /worktree.
#
# Fail-open: anything uncertain (not a repo, git missing, command not
# extractable, registry unreadable) -> allow. A missed block is
# recoverable (the awareness banner + the next session's guard still
# fire); a guard that wrongly wedged every push would be far worse. The
# override (CLAUDE_ALLOW_SHARED_GIT=1 git ...) covers a stale-registry
# false block.
#
# The model + registry format live in session-registry.sh, which this
# file sources for its helpers.

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$HERE/session-registry.sh" || { printf '{}\n'; exit 0; }

INPUT=$(cat)
FLAT=$(printf '%s' "$INPUT" | tr -d '\n')
CMD=$(printf '%s' "$FLAT" | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p')

# No command extracted -> fail OPEN here (unlike pre-push which fails
# closed on its trailer gate). This guard can only ever block a small,
# explicit set of git verbs; if we cannot see the command we cannot have
# matched one, so blocking would be a guess.
[ -n "$CMD" ] || { printf '{}\n'; exit 0; }

# Anchor to a shell-segment start, allowing leading env-var assignments
# (so `CLAUDE_ALLOW_SHARED_GIT=1 git push` and `GIT_TRACE=1 git commit`
# are recognised, not evaded). Quoted prose like echo "... git push ..."
# is NOT a segment start, so it stays unmatched.
SEG='(^[[:space:]]*|[;&|(][[:space:]]*)([A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*[[:space:]]+)*'
GITO='git([[:space:]]+(-C[[:space:]]+[^[:space:];&|]+|-c[[:space:]]+[^[:space:];&|]+|--[^[:space:];&|]+))*'

is_dangerous=no
if   printf '%s' "$CMD" | grep -qE "${SEG}${GITO}[[:space:]]+(commit|push|merge|rebase|pull|cherry-pick|revert|am)([[:space:]]|[;&|)]|$)"; then is_dangerous=yes
elif printf '%s' "$CMD" | grep -qE "${SEG}${GITO}[[:space:]]+reset([[:space:]]+[^;&|]*)?--(hard|merge|keep)"; then is_dangerous=yes
elif printf '%s' "$CMD" | grep -qE "${SEG}${GITO}[[:space:]]+stash[[:space:]]+(pop|apply)"; then is_dangerous=yes
elif printf '%s' "$CMD" | grep -qE "${SEG}${GITO}[[:space:]]+apply([[:space:]]|$)"; then is_dangerous=yes
fi

if [ "$is_dangerous" = no ]; then
  printf '{}\n'; exit 0
fi

# Explicit override (inline on the command or in the environment).
if printf '%s' "$CMD" | grep -qE 'SENIOR_MODE_ALLOW_SHARED_GIT=1|CLAUDE_ALLOW_SHARED_GIT=1' || [ "${SENIOR_MODE_ALLOW_SHARED_GIT:-}" = "1" ] || [ "${CLAUDE_ALLOW_SHARED_GIT:-}" = "1" ]; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "Tangle guard overridden (SENIOR_MODE_ALLOW_SHARED_GIT=1). Proceeding on the shared checkout: make sure no other live session is mid-edit here."
  }
}
EOF
  exit 0
fi

# Resolve the repo from the session's cwd (so a worktree is seen as a
# worktree). Fail-open on anything unexpected.
RAW_CWD=$(reg_norm_path "$(reg_extract cwd "$FLAT")")
RAW_SID=$(reg_extract session_id "$FLAT")
REG_SID=$(printf '%s' "${RAW_SID:-unknown}" | tr -c 'A-Za-z0-9_.-' '_')
BASE="${RAW_CWD:-${SENIOR_MODE_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-${CURSOR_PROJECT_DIR:-${GEMINI_PROJECT_DIR:-.}}}}}"
reg_resolve "$BASE" || { printf '{}\n'; exit 0; }

# In our own worktree -> exactly the safe path. Allow silently.
if [ "$REG_INWT" = yes ]; then
  printf '{}\n'; exit 0
fi

reg_prune
REG_STARTED=$(reg_load_started)
reg_write 0                       # refresh heartbeat + ensure self counted

SAME=$(reg_same_tree)
N_SAME=$(reg_count "$SAME")
PEERS=$(( N_SAME > 0 ? N_SAME - 1 : 0 ))

# Solo in this checkout -> normal flow, allow.
if [ "$PEERS" -le 0 ]; then
  printf '{}\n'; exit 0
fi

# The incumbent owns the checkout, so its commit/push is allowed. But the
# guard only gates git, not Edit/Write: a later session that made
# uncommitted edits in this shared tree before isolating could have them
# swept into a `git add -A`. So warn (do not block) to stage explicitly.
if reg_am_incumbent; then
  WLIST=$(reg_json_escape "$(reg_fmt_same)")
  printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "PreToolUse",\n    "additionalContext": "Incumbent in a shared checkout with %s other live session(s) (%s). Proceeding, but stage explicit paths instead of `git add -A` so you do not sweep in their uncommitted (pre-isolation) edits."\n  }\n}\n' "$PEERS" "$WLIST"
  exit 0
fi

# Non-incumbent + shared checkout + tree-mutating git op -> BLOCK.
LIST=$(reg_json_escape "$(reg_fmt_same)")
REASON="Tangle guard: BLOCKED. ${PEERS} other live agent session(s) share this checkout (${REG_TOP}) and you are NOT the incumbent. Committing or pushing from a shared working tree is what tangles the tree (recovery usually costs a hard reset).\\n\\nDo this instead: run \`/worktree\` to move onto your own branch + worktree off origin/${REG_MAIN}, then commit/push from there. Sibling worktrees never tangle; you only coordinate the final push (fetch + rebase + push).\\n\\nLive in this checkout: ${LIST}.\\n\\nIf that other session is actually dead (stale entry), override once: prefix the command with SENIOR_MODE_ALLOW_SHARED_GIT=1."

printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "PreToolUse",\n    "permissionDecision": "deny",\n    "permissionDecisionReason": "%s"\n  }\n}\n' "$REASON"
exit 0
