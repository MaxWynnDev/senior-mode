#!/usr/bin/env bash
# Adapters for the agents whose hook files ARE the canonical format with a
# different file name: Factory Droid, Devin CLI, Augment (Auggie). Plus the
# generic target for AGENTS.md + skills only (Windsurf, Kiro, Amp, Zed, Warp,
# Jules, Junie, Cline, Aider): those agents read AGENTS.md at the root and
# Agent Skills from .agents/skills; they have no shell-hook contract this kit
# can verify, so nothing else is generated for them.
#
#   generate.sh <factory|devin|augment|generic> <target>
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"
AGENT="$1"; SM_TARGET="$(cd "$2" && pwd)"
ROOT='$(git rev-parse --show-toplevel)'

skills() {
  for f in "$SM_KIT"/core/commands/*.md; do sm_skill_from_command "$f" "$SM_TARGET/.agents/skills"; done
  if [ -n "$SM_STACK" ] && [ -d "$SM_KIT/stacks/$SM_STACK/commands" ]; then
    for f in "$SM_KIT/stacks/$SM_STACK/commands"/*.md; do [ -f "$f" ] && sm_skill_from_command "$f" "$SM_TARGET/.agents/skills"; done
  fi
}
commands_dir() { # <dir>  copies commands as-is (description / argument-hint / $ARGUMENTS are shared conventions)
  for f in "$SM_KIT"/core/commands/*.md; do sm_copy "$f" "$1/$(basename "$f")"; done
  if [ -n "$SM_STACK" ] && [ -d "$SM_KIT/stacks/$SM_STACK/commands" ]; then
    for f in "$SM_KIT/stacks/$SM_STACK/commands"/*.md; do [ -f "$f" ] && sm_copy "$f" "$1/$(basename "$f")"; done
  fi
}
reviewers_md() { # <dir> <suffix>  frontmatter name/description/tools kept (the shared shape)
  for f in "$SM_KIT"/core/reviewers/*.md; do
    name=$(sm_fm_get "$f" name); [ -n "$name" ] || name=$(basename "$f" .md)
    sm_copy "$f" "$1/$name$2"
  done
}

case "$AGENT" in
  factory)
    # Factory's tool vocabulary: shell commands run as Execute, file edits as
    # Create/Edit/ApplyPatch (the docs' own formatter example); there is no
    # Bash tool, so Claude-name matchers never fire. Hook commands run from
    # Droid's cwd, which can differ from the repo root, so the documented
    # idiom is an absolute path via $FACTORY_PROJECT_DIR.
    sm_hooks_json '$FACTORY_PROJECT_DIR' no timeout 1 command Execute 'Create|Edit|ApplyPatch' | sm_put "$SM_TARGET/.factory/hooks.json"
    commands_dir "$SM_TARGET/.factory/commands"
    reviewers_md "$SM_TARGET/.factory/droids" ".md"
    skills ;;
  devin)
    # Devin's tool vocabulary: shell commands run as exec, file edits as
    # write/edit/apply_patch; no Bash alias is documented. Its PreToolUse
    # deny channel is a top-level {"decision":"block"}, not the nested
    # permissionDecision, so the shell guards run through devin-shim.sh.
    # Everything else speaks the canonical contract natively (nested
    # additionalContext on UserPromptSubmit/SessionStart, Stop
    # decision/reason). Devin's docs do not mention stop_hook_active, so
    # the loop cap at turn end is the sentinel in senior-check-after.sh,
    # not the flag. DEVIN_PROJECT_DIR is the documented project root for
    # hook commands.
    DR='$DEVIN_PROJECT_DIR'
    DH="$DR/.senior-mode/hooks"
    cat <<EOF | sm_put "$SM_TARGET/.devin/hooks.v1.json"
{
  "SessionStart": [
    { "hooks": [ { "type": "command", "command": "bash \\"$DH/session-registry.sh\\" register", "timeout": 15 } ] }
  ],
  "SessionEnd": [
    { "hooks": [ { "type": "command", "command": "bash \\"$DH/session-registry.sh\\" unregister", "timeout": 3 } ] }
  ],
  "UserPromptSubmit": [
    { "hooks": [ { "type": "command", "command": "bash \\"$DH/session-registry.sh\\" touch", "timeout": 15 }, { "type": "command", "command": "bash \\"$DH/senior-check-before.sh\\"", "timeout": 10 }, { "type": "command", "command": "bash \\"$DH/ultracode-advisor.sh\\"", "timeout": 10 } ] }
  ],
  "PreToolUse": [
    { "matcher": "exec", "hooks": [ { "type": "command", "command": "bash \\"$DR/.senior-mode/adapters/devin-shim.sh\\" guard \\"$DH/session-tree-guard.sh\\" \\"$DH/pre-commit-audit.sh\\" \\"$DH/pre-push-checklist.sh\\" \\"$DH/exit-code-mask-guard.sh\\"", "timeout": 20 } ] }
  ],
  "PostToolUse": [
    { "matcher": "write|edit|apply_patch", "hooks": [ { "type": "command", "command": "bash \\"$DH/post-edit-format.sh\\"", "timeout": 30 } ] }
  ],
  "Stop": [
    { "hooks": [ { "type": "command", "command": "bash \\"$DH/senior-check-after.sh\\"", "timeout": 5 } ] }
  ]
}
EOF
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      name=$(basename "$f" .md); globs=$(sm_rule_globs "$f")
      {
        if [ -n "$globs" ]; then printf -- '---\ntrigger: glob\nglobs: %s\n---\n' "$globs"
        else printf -- '---\ntrigger: model_decision\ndescription: %s\n---\n' "$(sm_first_line "$f")"; fi
        sm_body "$f"
      } | sm_put "$SM_TARGET/.devin/rules/$name.md"
    done < <(sm_rule_files)
    skills ;;
  augment)
    # Augment's hook command is a bare script path (.sh with a shebang,
    # executable, no arguments documented), its event enum has no
    # UserPromptSubmit, its stdin names the session conversation_id, and its
    # Stop output nests decision/reason inside hookSpecificOutput. So each
    # event points at a generated wrapper in .augment/hooks/ that execs
    # augment-shim.sh with the right mode and hooks. The BEFORE checklist
    # arrives once per session via SessionStart (documented for
    # additionalContext); with no per-prompt event there is no registry
    # touch and no ultracode advisory. Timeouts are milliseconds.
    # Project-level .augment/settings.json is read by the Auggie CLI only;
    # the IDE extensions read user-level settings.
    AH="$SM_TARGET/.augment/hooks"
    aug_wrapper() { # <name> <shim-mode-and-args...>
      local name="$1"; shift
      {
        printf '#!/usr/bin/env bash\n'
        printf '# Generated by senior-mode (adapters/family). Augment hook commands are\n'
        printf '# bare script paths, so this wrapper supplies the mode and arguments.\n'
        printf 'ROOT="${AUGMENT_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"\n'
        printf 'exec bash "$ROOT/.senior-mode/adapters/augment-shim.sh"'
        local a; for a in "$@"; do printf ' %s' "$a"; done
        printf '\n'
      } | sm_put "$AH/$name"
      [ "$SM_DRY" = yes ] || [ ! -f "$AH/$name" ] || chmod +x "$AH/$name"
    }
    aug_wrapper senior-session-start.sh session-start '"$ROOT/.senior-mode/hooks/session-registry.sh:register"' '"$ROOT/.senior-mode/hooks/senior-check-before.sh"'
    aug_wrapper senior-session-end.sh   session-end   '"$ROOT/.senior-mode/hooks/session-registry.sh:unregister"'
    aug_wrapper senior-guards.sh        guard         '"$ROOT/.senior-mode/hooks/session-tree-guard.sh"' '"$ROOT/.senior-mode/hooks/pre-commit-audit.sh"' '"$ROOT/.senior-mode/hooks/pre-push-checklist.sh"' '"$ROOT/.senior-mode/hooks/exit-code-mask-guard.sh"'
    aug_wrapper senior-format.sh        format        '"$ROOT/.senior-mode/hooks/post-edit-format.sh"'
    aug_wrapper senior-stop.sh          stop          '"$ROOT/.senior-mode/hooks/senior-check-after.sh"'
    cat <<'EOF' | sm_put "$SM_TARGET/.augment/settings.json"
{
  "$comment": "Generated by senior-mode (adapters/family). Timeouts are milliseconds. Augment's command field is a bare script path, so each entry points at a wrapper in .augment/hooks (relative to the workspace root; the docs do not spell out relative-path resolution, so a live report either way is welcome). Read by the Auggie CLI; IDE extensions read user-level settings only.",
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": ".augment/hooks/senior-session-start.sh", "timeout": 15000 } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": ".augment/hooks/senior-session-end.sh", "timeout": 3000 } ] }
    ],
    "PreToolUse": [
      { "matcher": "launch-process", "hooks": [ { "type": "command", "command": ".augment/hooks/senior-guards.sh", "timeout": 20000 } ] }
    ],
    "PostToolUse": [
      { "matcher": "save-file|str-replace-editor", "hooks": [ { "type": "command", "command": ".augment/hooks/senior-format.sh", "timeout": 30000 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": ".augment/hooks/senior-stop.sh", "timeout": 5000 } ] }
    ]
  }
}
EOF
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      name=$(basename "$f" .md)
      { printf -- '---\ntype: agent_requested\ndescription: %s\n---\n' "$(sm_first_line "$f")"; sm_body "$f"; } | sm_put "$SM_TARGET/.augment/rules/$name.md"
    done < <(sm_rule_files)
    commands_dir "$SM_TARGET/.augment/commands"
    skills ;;
  generic)
    skills ;;
  *) sm_say "unknown family agent: $AGENT"; exit 1 ;;
esac
