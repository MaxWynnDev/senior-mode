#!/usr/bin/env bash
# senior-mode starter installer: the 5-minute global setup, per agent.
# Installs under the agent's home directory so it applies in every repo.
# Never overwrites: an existing file that differs gets the new version
# written beside it as <file>.starter for you to merge. Safe to re-run.
#
#   bash install.sh                       Claude Code (default)
#   bash install.sh --agent codex         one of: claude codex cursor gemini copilot opencode all
#   bash install.sh --agent all --dry-run print what would happen, change nothing
#
# What each agent gets (global):
#   claude    ~/.claude/CLAUDE.md, settings.json (2 hooks), hooks/, commands/review.md, docs
#   codex     ~/.codex/AGENTS.md, ~/.codex/hooks.json (2 hooks, same format), ~/.agents/skills/review, docs
#   cursor    ~/.cursor/hooks.json (2 hooks via the shim), ~/.cursor/skills/review, docs;
#             User Rules are not file-based in Cursor: paste ~/.cursor/senior-mode/AGENTS.md into Settings > Rules
#   gemini    ~/.gemini/GEMINI.md, ~/.gemini/settings.json (2 hooks via the shim), ~/.gemini/commands/review.toml, docs
#   copilot   ~/.copilot/copilot-instructions.md, ~/.copilot/hooks/senior-mode.json, ~/.copilot/skills/review, docs
#   opencode  ~/.config/opencode/AGENTS.md, plugins/senior-mode.ts (BEFORE check), commands/review.md, docs

set -euo pipefail

AGENT=claude; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT="${2:-claude}"; shift 2 ;;
    --agent=*) AGENT="${1#*=}"; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
say() { printf '%s\n' "$*"; }

put() { # put <relative source|-> <absolute destination>   ("-" reads stdin)
  local from="$1" to="$2" tmp
  tmp="$(mktemp)"
  if [ "$from" = "-" ]; then cat > "$tmp"; else
    [ -f "$SRC/$from" ] || { say "  skip   $from (not in starter)"; rm -f "$tmp"; return 0; }
    cat "$SRC/$from" > "$tmp"
  fi
  if [ -f "$to" ]; then
    if cmp -s "$tmp" "$to"; then say "  same   $to"; rm -f "$tmp"; return 0; fi
    say "  keep   $to  (yours differs; new version at ${to}.starter)"
    [ "$DRY" = 1 ] || cp "$tmp" "${to}.starter"
    rm -f "$tmp"; return 0
  fi
  say "  write  $to"
  if [ "$DRY" = 0 ]; then mkdir -p "$(dirname "$to")"; cp "$tmp" "$to"; fi
  rm -f "$tmp"
}
agents_md() { sed "s|{{DOCS}}|$1|g" "$SRC/AGENTS.md"; }   # <docs-dir>
docs() { # docs <dir>  the doctrine + prompting guide + hooks (+ shims)
  put ENGINEERING-PRINCIPLES.md "$1/ENGINEERING-PRINCIPLES.md"
  put PROMPTING-CODING-AGENTS.md "$1/PROMPTING-CODING-AGENTS.md"
  put hooks/senior-check-before.sh "$1/hooks/senior-check-before.sh"
  put hooks/senior-check-after.sh  "$1/hooks/senior-check-after.sh"
}
skill_review() { # skill_review <skills-dir>
  { printf -- '---\nname: review\ndescription: Quick single-reviewer pass over the current diff (bugs, safety, quality). Informational only.\n---\n'
    sed '1,/^---$/d' "$SRC/commands/review.md" | sed '1,/^---$/d'; } | put - "$1/review/SKILL.md"
}
canonical_hooks_json() { # canonical_hooks_json <hooks-dir> [ckey] [tkey]   two hooks, Claude/Codex/Copilot format
  local h="$1" ckey="${2:-command}" tkey="${3:-timeout}"
  cat <<EOF
{
  "\$comment": "senior-mode starter: two mindset hooks. Both fail open. Remove the Stop block if the end-of-turn self-check feels like nagging.",
  "hooks": {
    "UserPromptSubmit": [ { "hooks": [ { "type": "command", "$ckey": "bash \"$h/senior-check-before.sh\"", "$tkey": 10 } ] } ],
    "Stop":             [ { "hooks": [ { "type": "command", "$ckey": "bash \"$h/senior-check-after.sh\"",  "$tkey": 5 } ] } ]
  }
}
EOF
}

say "senior-mode starter -> agent: $AGENT$([ "$DRY" = 1 ] && printf ' (dry run)')"
LIST="$AGENT"; [ "$AGENT" = all ] && LIST="claude codex cursor gemini copilot opencode"
for a in $LIST; do
  case "$a" in
    claude)
      D="$HOME/.claude"
      say "[claude] $D"
      put CLAUDE.md "$D/CLAUDE.md"
      put PROMPTING-CODING-AGENTS.md "$D/PROMPTING-CODING-AGENTS.md"
      put ENGINEERING-PRINCIPLES.md "$D/ENGINEERING-PRINCIPLES.md"
      put settings.json "$D/settings.json"
      put hooks/senior-check-before.sh "$D/hooks/senior-check-before.sh"
      put hooks/senior-check-after.sh  "$D/hooks/senior-check-after.sh"
      put commands/review.md "$D/commands/review.md" ;;
    codex)
      D="$HOME/.codex"; S="$D/senior-mode"
      say "[codex] $D"
      agents_md "$S" | put - "$D/AGENTS.md"
      docs "$S"
      canonical_hooks_json "\$HOME/.codex/senior-mode/hooks" | put - "$D/hooks.json"
      skill_review "$HOME/.agents/skills" ;;
    cursor)
      D="$HOME/.cursor"; S="$D/senior-mode"
      say "[cursor] $D"
      agents_md "$S" | put - "$S/AGENTS.md"
      docs "$S"
      put adapters/cursor-shim.sh "$S/adapters/cursor-shim.sh"
      cat <<EOF | put - "$D/hooks.json"
{
  "version": 1,
  "\$comment": "senior-mode starter: the BEFORE checklist once per session, the AFTER check once per turn. Fail-open.",
  "hooks": {
    "sessionStart": [ { "command": "bash \"\$HOME/.cursor/senior-mode/adapters/cursor-shim.sh\" session \"\$HOME/.cursor/senior-mode/hooks/senior-check-before.sh\"", "timeout": 10 } ],
    "stop":         [ { "command": "bash \"\$HOME/.cursor/senior-mode/adapters/cursor-shim.sh\" stop \"\$HOME/.cursor/senior-mode/hooks/senior-check-after.sh\"", "timeout": 5, "loop_limit": 1 } ]
  }
}
EOF
      skill_review "$D/skills"
      say "  note   Cursor's User Rules live in Settings > Rules, not a file: paste $S/AGENTS.md there once." ;;
    gemini)
      D="$HOME/.gemini"; S="$D/senior-mode"
      say "[gemini] $D"
      agents_md "$S" | put - "$D/GEMINI.md"
      docs "$S"
      put adapters/gemini-shim.sh "$S/adapters/gemini-shim.sh"
      cat <<EOF | put - "$D/settings.json"
{
  "\$comment": "senior-mode starter: BEFORE checklist on every prompt, AFTER check as a system message. Timeouts in ms. Fail-open.",
  "hooks": {
    "BeforeAgent": [ { "hooks": [ { "name": "senior-mode-before", "type": "command", "command": "bash \"\$HOME/.gemini/senior-mode/adapters/gemini-shim.sh\" BeforeAgent \"\$HOME/.gemini/senior-mode/hooks/senior-check-before.sh\"", "timeout": 10000 } ] } ],
    "AfterAgent":  [ { "hooks": [ { "name": "senior-mode-after",  "type": "command", "command": "bash \"\$HOME/.gemini/senior-mode/adapters/gemini-shim.sh\" AfterAgent \"\$HOME/.gemini/senior-mode/hooks/senior-check-after.sh\"", "timeout": 5000 } ] } ]
  }
}
EOF
      { printf 'description = "Quick single-reviewer pass over the current diff (bugs, safety, quality)."\nprompt = '"'''"'\n'; sed '1,/^---$/d' "$SRC/commands/review.md" | sed '1,/^---$/d'; printf "'''\n"; } | put - "$D/commands/review.toml" ;;
    copilot)
      D="$HOME/.copilot"; S="$D/senior-mode"
      say "[copilot] $D"
      agents_md "$S" | put - "$D/copilot-instructions.md"
      docs "$S"
      { printf '{\n  "version": 1,\n'; canonical_hooks_json "\$HOME/.copilot/senior-mode/hooks" bash timeoutSec | sed '1d'; } | put - "$D/hooks/senior-mode.json"
      skill_review "$D/skills" ;;
    opencode)
      D="$HOME/.config/opencode"; S="$D/senior-mode"
      say "[opencode] $D"
      agents_md "$S" | put - "$D/AGENTS.md"
      docs "$S"
      cat <<'EOF' | sed "s|__HOOKS__|$S/hooks|" | put - "$D/plugins/senior-mode.ts"
// senior-mode starter (OpenCode): pushes the BEFORE checklist into the system prompt once per turn.
import type { Plugin } from "@opencode-ai/plugin";
export const SeniorModeStarter: Plugin = async ({ $ }) => ({
  "experimental.chat.system.transform": async (input, output) => {
    try {
      const out = await $`bash __HOOKS__/senior-check-before.sh`.quiet().nothrow().stdin(JSON.stringify({ session_id: input.sessionID ?? "opencode", hook_event_name: "UserPromptSubmit", prompt: "" }));
      const m = out.stdout.toString().replace(/\n/g, " ").match(/"additionalContext"\s*:\s*"((?:[^"\\]|\\.)*)"/);
      if (m) output.system.push(m[1].replace(/\\n/g, "\n").replace(/\\"/g, '"'));
    } catch {}
  },
});
EOF
      put commands/review.md "$D/commands/review.md" ;;
    *) echo "unknown agent: $a (claude codex cursor gemini copilot opencode all)" >&2; exit 1 ;;
  esac
done

if [ "$DRY" = 0 ]; then
  find "$HOME/.claude/hooks" "$HOME/.codex/senior-mode" "$HOME/.cursor/senior-mode" "$HOME/.gemini/senior-mode" "$HOME/.copilot/senior-mode" "$HOME/.config/opencode/senior-mode" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
fi

say ""
say "Done. Files marked 'keep' have a .starter version beside them: merge by hand (your agent can do it: open the file and ask)."
say "Open any repo in your agent; the first prompt should carry [SENIOR CHECK | BEFORE]. Codex: run /hooks once to approve."
say "On Windows, run your agent and this script from Git Bash so 'bash' is on PATH."
