#!/usr/bin/env bash
# Codex CLI adapter. Codex hooks are stable and use the canonical format
# (same event names, matcher, hookSpecificOutput), so the scripts run unchanged.
#   .codex/hooks.json          canonical hooks; repo root via git rev-parse (the docs' own idiom)
#   .codex/agents/*.toml       reviewers as Codex custom agents (multi_agent is on by default)
#   .agents/skills/*/SKILL.md  commands as Agent Skills (Codex reads .agents/skills; custom prompts are deprecated)
# Rules: Codex has no path-scoped rules; AGENTS.md (root, written by install.sh)
# carries a "read this rule before touching these paths" table, and
# install.sh --nested-rules can drop AGENTS.md files into the layout dirs.
# Project .codex/ layers load only for a trusted project, and hooks must be
# approved once via /hooks.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"
SM_TARGET="$(cd "$1" && pwd)"

sm_hooks_json '$(git rev-parse --show-toplevel)' yes | sm_put "$SM_TARGET/.codex/hooks.json"

for f in "$SM_KIT"/core/reviewers/*.md; do
  name=$(sm_fm_get "$f" name); [ -n "$name" ] || name=$(basename "$f" .md)
  desc=$(sm_fm_get "$f" description)
  tools=$(sm_fm_get "$f" tools)
  sandbox="workspace-write"
  case "$tools" in *Edit*|*Write*) ;; *) sandbox="read-only" ;; esac
  {
    printf '# Generated from core/reviewers/%s.md by senior-mode; edit the source, then re-run install.sh.\n' "$name"
    printf 'name = "%s"\n' "$name"
    printf 'description = "%s"\n' "$(printf '%s' "$desc" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    printf 'sandbox_mode = "%s"\n' "$sandbox"
    printf "developer_instructions = '''\n"
    sm_body "$f" | sed "s/'''/''\\\\''/g"
    printf "'''\n"
  } | sm_put "$SM_TARGET/.codex/agents/$name.toml"
done

for f in "$SM_KIT"/core/commands/*.md; do sm_skill_from_command "$f" "$SM_TARGET/.agents/skills"; done
if [ -n "$SM_STACK" ] && [ -d "$SM_KIT/stacks/$SM_STACK/commands" ]; then
  for f in "$SM_KIT/stacks/$SM_STACK/commands"/*.md; do [ -f "$f" ] && sm_skill_from_command "$f" "$SM_TARGET/.agents/skills"; done
fi
