#!/usr/bin/env bash
# Shared helpers for the senior-mode adapters. Sourced by install.sh and by
# every adapters/<agent>/generate.sh. Pure bash: no jq, no python, so it
# runs wherever the hooks run (macOS, Linux, Windows Git Bash).
#
# Contract for a generator:  bash adapters/<agent>/generate.sh <target-repo>
# Environment: SM_KIT (kit root), SM_DRY (yes|no), SM_FORCE (yes|no),
#              SM_STACK (profile name or empty). All set by install.sh; a
#              generator run by hand gets sane defaults below.

SM_KIT="${SM_KIT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SM_DRY="${SM_DRY:-no}"
SM_FORCE="${SM_FORCE:-no}"
SM_STACK="${SM_STACK:-}"
SM_MERGE_LIST="${SM_MERGE_LIST:-}"   # accumulates "<path>" entries that need a hand merge

sm_say() { printf '[senior-mode] %s\n' "$*"; }

# sm_put <dest-path>   (content on stdin)
# Non-clobbering: writes when absent; skips when byte-identical; otherwise
# writes <dest>.senior-mode beside it and records it for the MERGE list.
sm_put() {
  local dest="$1" tmp
  tmp="$(mktemp)"; cat > "$tmp"
  if [ -f "$dest" ]; then
    if cmp -s "$tmp" "$dest"; then sm_say "same    ${dest#$SM_TARGET/}"; rm -f "$tmp"; return 0; fi
    if [ "$SM_FORCE" = yes ]; then
      sm_say "replace ${dest#$SM_TARGET/}"
      [ "$SM_DRY" = yes ] || mv -f "$tmp" "$dest"; [ "$SM_DRY" = yes ] && rm -f "$tmp"; return 0
    fi
    sm_say "keep    ${dest#$SM_TARGET/}  (differs; new version at ${dest#$SM_TARGET/}.senior-mode)"
    SM_MERGE_LIST="$SM_MERGE_LIST
${dest#$SM_TARGET/}.senior-mode"
    [ "$SM_DRY" = yes ] || mv -f "$tmp" "$dest.senior-mode"; [ "$SM_DRY" = yes ] && rm -f "$tmp"; return 0
  fi
  sm_say "write   ${dest#$SM_TARGET/}"
  if [ "$SM_DRY" = yes ]; then rm -f "$tmp"; else mkdir -p "$(dirname "$dest")"; mv -f "$tmp" "$dest"; fi
}

# sm_copy <src-file> <dest-path>
sm_copy() { sm_put "$2" < "$1"; }

# sm_json_escape <string>  -> JSON string body (no surrounding quotes)
sm_json_escape() {
  local s="$1"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# --- frontmatter helpers (the core files use simple `key: value` YAML) ------
# sm_fm_get <file> <key>   -> value (first match inside the leading --- block)
sm_fm_get() {
  awk -v k="$2" '
    NR==1 && $0!="---" { exit }
    NR>1 && $0=="---" { exit }
    NR>1 { i=index($0,":"); if (i>0 && substr($0,1,i-1)==k) { v=substr($0,i+1); sub(/^[ \t]+/,"",v); sub(/[ \t]+$/,"",v); gsub(/^"|"$/,"",v); print v; exit } }
  ' "$1"
}
# sm_body <file>  -> everything after the leading --- block (or the whole file)
sm_body() {
  awk 'NR==1 && $0=="---" { infm=1; next } infm && $0=="---" { infm=0; next } !infm { print }' "$1"
}
# sm_first_heading_or_line <file> -> a one-line description for files without frontmatter
sm_first_line() {
  awk 'NR==1 && $0=="---" { infm=1; next } infm && $0=="---" { infm=0; next } infm { next }
       /^<!--/ { skip=1 } skip && /-->/ { skip=0; next } skip { next } /^[[:space:]]*$/ { next } { sub(/^#+[ \t]*/,""); print; exit }' "$1"
}

# --- hook command lines ------------------------------------------------------
# sm_hook_cmd <projectdir-expr> <script> [args]
# projectdir-expr is how the agent exposes the repo root to a hook command.
sm_hook_cmd() {
  local root="$1" script="$2"; shift 2
  local extra=""; [ $# -gt 0 ] && extra=" $*"
  printf 'bash "%s/.senior-mode/hooks/%s"%s' "$root" "$script" "$extra"
}

# The canonical event wiring, shared by every Claude-format agent.
# Each line: <Event> <matcher-or-empty> <script> [args]
sm_canonical_events() {
  cat <<'EOF'
SessionStart      -        session-registry.sh register
SessionEnd        -        session-registry.sh unregister
UserPromptSubmit  -        session-registry.sh touch
UserPromptSubmit  -        senior-check-before.sh
UserPromptSubmit  -        ultracode-advisor.sh
PreToolUse        Bash     session-tree-guard.sh
PreToolUse        Bash     pre-commit-audit.sh
PreToolUse        Bash     pre-push-checklist.sh
PreToolUse        Bash     exit-code-mask-guard.sh
PostToolUse       Write|Edit post-edit-format.sh
Stop              -        senior-check-after.sh
EOF
}

# sm_hooks_json <projectdir-expr> [top-level:yes|no] [timeout-key] [timeout-scale]
# Emits the {"hooks": {...}} object (or the bare inner object when top-level=no,
# for Factory/Devin whose file IS the inner object). timeout-key defaults to
# "timeout" (seconds); Augment wants milliseconds (scale 1000).
sm_hooks_json() {
  local root="$1" top="${2:-yes}" tkey="${3:-timeout}" tscale="${4:-1}" ckey="${5:-command}"
  local ev prev_ev="" prev_m="" first_ev=yes first_h=yes
  if [ "$top" = yes ]; then printf '{\n  "hooks": {\n'; else printf '{\n'; fi
  local indent="    "; [ "$top" = no ] && indent="  "
  # group consecutive lines by (event, matcher)
  local line event matcher script args
  local SEP=$''   # matchers contain "|", so group fields are joined with a control char
  local -a groups=()
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    set -- $line; event=$1; matcher=$2; script=$3; shift 3; args="$*"
    local t=10; case "$script" in post-edit-format.sh) t=30;; session-registry.sh) t=15;; pre-commit-audit.sh) t=15;; senior-check-after.sh) t=5;; esac
    # Codex caps SessionEnd hooks at 3 seconds (default 1). Unregister is one
    # rm, so the cap fits every adapter; one canonical value beats a per-agent
    # override.
    [ "$event" = "SessionEnd" ] && t=3
    t=$((t * tscale))
    local cmd; cmd=$(sm_json_escape "$(sm_hook_cmd "$root" "$script" $args)")
    local entry="{ \"type\": \"command\", \"$ckey\": \"$cmd\", \"$tkey\": $t }"
    if [ "$event" = "$prev_ev" ] && [ "$matcher" = "$prev_m" ]; then
      groups[${#groups[@]}-1]="${groups[${#groups[@]}-1]}, $entry"
    else
      groups+=("$event${SEP}$matcher${SEP}$entry")
      prev_ev=$event; prev_m=$matcher
    fi
  done < <(sm_canonical_events)
  # emit, merging groups that share an event into one array
  local cur_ev="" g gev gm gentries
  for g in "${groups[@]}"; do
    gev=${g%%"$SEP"*}; g=${g#*"$SEP"}; gm=${g%%"$SEP"*}; gentries=${g#*"$SEP"}
    if [ "$gev" != "$cur_ev" ]; then
      [ -n "$cur_ev" ] && printf '\n%s]' "$indent"
      [ "$first_ev" = yes ] || printf ','
      first_ev=no
      printf '\n%s"%s": [' "$indent" "$gev"
      cur_ev=$gev; first_h=yes
    fi
    [ "$first_h" = yes ] || printf ','
    first_h=no
    if [ "$gm" = "-" ]; then
      printf '\n%s  { "hooks": [ %s ] }' "$indent" "$gentries"
    else
      printf '\n%s  { "matcher": "%s", "hooks": [ %s ] }' "$indent" "$(sm_json_escape "$gm")" "$gentries"
    fi
  done
  [ -n "$cur_ev" ] && printf '\n%s]' "$indent"
  if [ "$top" = yes ]; then printf '\n  }\n}\n'; else printf '\n}\n'; fi
}

# sm_rule_files -> list of rule files to install: stack rules override core
# rules of the same name; the rest of the core comes along.
sm_rule_files() {
  local core="$SM_KIT/core/rules" stack="" f name
  [ -n "$SM_STACK" ] && [ -d "$SM_KIT/stacks/$SM_STACK/rules" ] && stack="$SM_KIT/stacks/$SM_STACK/rules"
  if [ -n "$stack" ]; then for f in "$stack"/*.md; do [ -f "$f" ] && printf '%s\n' "$f"; done; fi
  for f in "$core"/*.md; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    # a stack rule that covers the same layer replaces the core one
    case "$name" in
      api-boundary.md) [ -n "$stack" ] && [ -f "$stack/api-routes.md" ] && continue ;;
      data-layer.md)   [ -n "$stack" ] && [ -f "$stack/database.md" ] && continue ;;
      ui.md)           [ -n "$stack" ] && [ -f "$stack/components.md" ] && continue ;;
      services.md|scripts.md) [ -n "$stack" ] && [ -f "$stack/$name" ] && continue ;;
    esac
    printf '%s\n' "$f"
  done
}

# sm_rule_globs <rule-file> -> the suggested globs for a rule, taken from the
# `paths:` list inside its SETUP comment (lines like `#   - "**/api/**"`), as a
# comma-separated string. Empty when the file has no suggestion.
sm_rule_globs() {
  awk '
    /paths:/ { on=1; next }
    on && /^[ \t#]*- / { g=$0; sub(/^[ \t#]*- */,"",g); gsub(/["'"'"']/,"",g); sub(/[ \t]+$/,"",g); if (out!="") out=out ","; out=out g; next }
    on && !/^[ \t#]*- / { on=0 }
    END { print out }
  ' "$1"
}

# sm_skill_from_command <command.md> <skill-dir>
# Turns a slash-command definition into an Agent Skill (SKILL.md), the format
# Cursor, Codex, Gemini, Copilot, OpenCode, Amp, Zed, Warp, Junie, Factory,
# Augment and Devin CLI all read from .agents/skills/<name>/SKILL.md.
sm_skill_from_command() {
  [ "${SM_SKILLS_DONE:-no}" = yes ] && return 0   # install.sh generates the shared skills once (the generic pass)
  local src="$1" dir="$2" name desc hint
  name=$(basename "$src" .md)
  desc=$(sm_fm_get "$src" description); [ -n "$desc" ] || desc="$name procedure"
  hint=$(sm_fm_get "$src" argument-hint)
  {
    printf -- '---\nname: %s\ndescription: %s\n---\n' "$name" "$(printf '%s' "$desc" | sed 's/"/\\"/g')"
    printf '<!-- Generated from core/commands/%s.md by senior-mode; edit the source, then re-run install.sh. -->\n\n' "$name"
    [ -n "$hint" ] && printf 'Arguments: `%s`. When invoked with text after the skill name, treat it as `$ARGUMENTS` below; when invoked bare, `$ARGUMENTS` is empty.\n\n' "$hint"
    sm_body "$src"
  } | sm_put "$dir/$name/SKILL.md"
}
