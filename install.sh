#!/usr/bin/env bash
# senior-mode installer. Installs the universal core into a repository and
# generates the wiring for whichever coding agents you use, WITHOUT clobbering
# anything that already exists there.
#
# Usage:
#   bash install.sh [options] <target-repo-dir>
#
#   --agent <list|auto|all|none>   comma-separated agents to wire (default: auto).
#                                  claude codex cursor gemini copilot opencode
#                                  factory devin augment generic
#                                  auto  = agents whose config dir exists in the
#                                          target or whose CLI is on PATH
#                                  all   = every adapter
#                                  none  = universal files only (AGENTS.md, .senior-mode/, .agents/skills)
#   --stack <name|auto|none>       stack profile overlay (default: auto).
#                                  auto = stacks/detect.sh; installs a profile only
#                                  on a confident detection, otherwise leaves the
#                                  pick to the kickoff (see stacks/README.md)
#   --dry-run                      print what would happen; write nothing
#   --force                        overwrite files that exist and differ
#   --list-stacks                  print the stack picker and exit
#
# Rules:
#   - A file that does not exist in the target is written.
#   - A file that exists and is byte-identical is skipped.
#   - A file that exists and differs is NOT touched: the new version is written
#     beside it as <file>.senior-mode and listed under MERGE at the end. The
#     kickoff prompt merges those with you.
#   - Nothing is ever deleted.
#
# What lands where:
#   <target>/.senior-mode/        the source of truth: hooks, rules, reviewers,
#                                 commands, memory, adapters/shims, stacks/
#   <target>/AGENTS.md            the universal entry point (every agent reads it)
#   <target>/CLAUDE.md            Claude Code shim that imports AGENTS.md
#   <target>/ENGINEERING-PRINCIPLES.md, PROMPT-STANDARD.md, PROMPTING.md, WORKFLOW.md
#   <target>/.agents/skills/      procedures as Agent Skills (read by most agents)
#   <target>/.<agent>/...         per-agent wiring from adapters/<agent>/generate.sh
#
# Exit code 0 on success, 1 on a usage error.

set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$KIT/adapters/_lib.sh"
SM_KIT="$KIT"

AGENTS_ARG=auto; STACK_ARG=auto; TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --agent|--agents) AGENTS_ARG="${2:-}"; shift 2 ;;
    --agent=*) AGENTS_ARG="${1#*=}"; shift ;;
    --stack|--profile) STACK_ARG="${2:-}"; shift 2 ;;
    --stack=*) STACK_ARG="${1#*=}"; shift ;;
    --dry-run) SM_DRY=yes; shift ;;
    --force) SM_FORCE=yes; shift ;;
    --list-stacks) bash "$KIT/stacks/detect.sh" --list; exit 0 ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    -*) echo "install: unknown option $1" >&2; exit 1 ;;
    *) TARGET="$1"; shift ;;
  esac
done
[ -n "$TARGET" ] || { echo "install: target directory required (see --help)" >&2; exit 1; }
mkdir -p "$TARGET" 2>/dev/null || true
SM_TARGET="$(cd "$TARGET" 2>/dev/null && pwd)" || { echo "install: cannot access $TARGET" >&2; exit 1; }
export SM_KIT SM_DRY SM_FORCE SM_TARGET

ALL_AGENTS="claude codex cursor gemini copilot opencode factory devin augment"

# ---- 1. which agents ---------------------------------------------------------
detect_agents() {
  local found=""
  has() { command -v "$1" >/dev/null 2>&1; }
  [ -d "$SM_TARGET/.claude" ]   || has claude   && found="$found claude"
  [ -d "$SM_TARGET/.codex" ]    || has codex    && found="$found codex"
  [ -d "$SM_TARGET/.cursor" ]   || has agent || has cursor-agent && found="$found cursor"
  [ -d "$SM_TARGET/.gemini" ]   || has gemini   && found="$found gemini"
  [ -f "$SM_TARGET/.github/copilot-instructions.md" ] || [ -d "$SM_TARGET/.github/hooks" ] || has copilot && found="$found copilot"
  [ -f "$SM_TARGET/opencode.json" ] || [ -d "$SM_TARGET/.opencode" ] || has opencode && found="$found opencode"
  [ -d "$SM_TARGET/.factory" ]  || has droid    && found="$found factory"
  [ -d "$SM_TARGET/.devin" ]    || has devin    && found="$found devin"
  [ -d "$SM_TARGET/.augment" ]  || has auggie   && found="$found augment"
  printf '%s' "${found# }"
}
case "$AGENTS_ARG" in
  auto) AGENTS=$(detect_agents); [ -n "$AGENTS" ] || AGENTS="generic"; AGENT_SRC="detected" ;;
  all)  AGENTS="$ALL_AGENTS"; AGENT_SRC="all" ;;
  none) AGENTS=""; AGENT_SRC="none" ;;
  *)    AGENTS=$(printf '%s' "$AGENTS_ARG" | tr ',' ' '); AGENT_SRC="requested" ;;
esac
for a in $AGENTS; do
  case " $ALL_AGENTS generic " in *" $a "*) ;; *) echo "install: unknown agent '$a' (choose from: $ALL_AGENTS generic)" >&2; exit 1 ;; esac
done

# ---- 2. which stack ----------------------------------------------------------
STACK_NOTE=""
case "$STACK_ARG" in
  none) SM_STACK="" ;;
  auto)
    DET=$(bash "$KIT/stacks/detect.sh" --json "$SM_TARGET")
    VERDICT=$(printf '%s' "$DET" | sed -n 's/.*"verdict":"\([A-Z]*\)".*/\1/p')
    BEST=$(printf '%s' "$DET" | sed -n 's/.*"best":"\([^"]*\)".*/\1/p')
    if [ "$VERDICT" = DETECTED ]; then SM_STACK="$BEST"; STACK_NOTE="detected"
    else SM_STACK=""; STACK_NOTE="$VERDICT: no profile installed; the kickoff runs the picker (bash .senior-mode/stacks/detect.sh --list)"; fi ;;
  *)
    [ -f "$KIT/stacks/$STACK_ARG/profile.json" ] || { echo "install: unknown stack '$STACK_ARG'. Available:" >&2; bash "$KIT/stacks/detect.sh" --list >&2; exit 1; }
    SM_STACK="$STACK_ARG"; STACK_NOTE="requested" ;;
esac
export SM_STACK

sm_say "kit:     $KIT"
sm_say "target:  $SM_TARGET"
sm_say "agents:  ${AGENTS:-(none)}  [$AGENT_SRC]"
sm_say "stack:   ${SM_STACK:-(none)}  [$STACK_NOTE]"
[ "$SM_DRY" = yes ] && sm_say "DRY RUN: nothing will be written"

# ---- 3. the core -> .senior-mode/ --------------------------------------------
copy_tree() { # <src-dir> <dest-dir>
  local src="$1" dest="$2" f rel
  [ -d "$src" ] || return 0
  while IFS= read -r f; do
    rel="${f#$src/}"
    sm_copy "$f" "$dest/$rel"
  done < <(find "$src" -type f | sort)
}
copy_tree "$KIT/core/hooks"     "$SM_TARGET/.senior-mode/hooks"
copy_tree "$KIT/core/rules"     "$SM_TARGET/.senior-mode/rules"
copy_tree "$KIT/core/reviewers" "$SM_TARGET/.senior-mode/reviewers"
copy_tree "$KIT/core/commands"  "$SM_TARGET/.senior-mode/commands"
copy_tree "$KIT/core/memory"    "$SM_TARGET/.senior-mode/memory"
copy_tree "$KIT/adapters/shims" "$SM_TARGET/.senior-mode/adapters"
sm_copy "$KIT/stacks/detect.sh" "$SM_TARGET/.senior-mode/stacks/detect.sh"
for p in "$KIT"/stacks/*/; do   # every profile's signals + card, so the picker works inside the repo
  n=$(basename "$p")
  [ -f "$p/detect.txt" ] && sm_copy "$p/detect.txt" "$SM_TARGET/.senior-mode/stacks/$n/detect.txt"
  [ -f "$p/profile.json" ] && sm_copy "$p/profile.json" "$SM_TARGET/.senior-mode/stacks/$n/profile.json"
done
if [ -n "$SM_STACK" ]; then copy_tree "$KIT/stacks/$SM_STACK" "$SM_TARGET/.senior-mode/stacks/$SM_STACK"; fi
sm_copy "$KIT/KICKOFF-PROMPT.md" "$SM_TARGET/.senior-mode/KICKOFF-PROMPT.md"
sm_copy "$KIT/SETUP.md"          "$SM_TARGET/.senior-mode/SETUP.md"
sm_copy "$KIT/STACK.md"          "$SM_TARGET/.senior-mode/STACK.md"
sm_copy "$KIT/stacks/README.md"  "$SM_TARGET/.senior-mode/stacks/README.md"
if [ "$SM_DRY" = no ]; then chmod +x "$SM_TARGET"/.senior-mode/hooks/*.sh "$SM_TARGET"/.senior-mode/adapters/*.sh "$SM_TARGET"/.senior-mode/stacks/detect.sh 2>/dev/null || true; fi

# ---- 4. root docs -------------------------------------------------------------
sm_copy "$KIT/core/AGENTS.md" "$SM_TARGET/AGENTS.md"
case " $AGENTS " in *" claude "*) sm_copy "$KIT/core/CLAUDE.md" "$SM_TARGET/CLAUDE.md" ;; esac
sm_copy "$KIT/ENGINEERING-PRINCIPLES.md" "$SM_TARGET/ENGINEERING-PRINCIPLES.md"
sm_copy "$KIT/PROMPT-STANDARD.md"        "$SM_TARGET/PROMPT-STANDARD.md"
sm_copy "$KIT/PROMPTING.md"              "$SM_TARGET/PROMPTING.md"
if [ -n "$SM_STACK" ] && [ -f "$KIT/stacks/$SM_STACK/WORKFLOW.md" ]; then
  sm_copy "$KIT/stacks/$SM_STACK/WORKFLOW.md" "$SM_TARGET/WORKFLOW.md"
  [ -f "$KIT/stacks/$SM_STACK/QA-SWEEP.md" ] && sm_copy "$KIT/stacks/$SM_STACK/QA-SWEEP.md" "$SM_TARGET/QA-SWEEP.md"
else
  sm_copy "$KIT/WORKFLOW.md" "$SM_TARGET/WORKFLOW.md"
fi

# ---- 5. per-agent wiring -------------------------------------------------------
# The universal skills dir is always produced (every agent below reads it).
bash "$KIT/adapters/family/generate.sh" generic "$SM_TARGET"
export SM_SKILLS_DONE=yes   # adapters skip the (identical) skills pass from here on
for a in $AGENTS; do
  case "$a" in
    generic) ;;
    factory|devin|augment) bash "$KIT/adapters/family/generate.sh" "$a" "$SM_TARGET" ;;
    *) bash "$KIT/adapters/$a/generate.sh" "$SM_TARGET" ;;
  esac
done

# ---- 6. warnings ---------------------------------------------------------------
if [ -f "$SM_TARGET/.gitignore" ]; then
  for pat in '.senior-mode' '.claude' '.agents' 'AGENTS.md'; do
    if grep -qE "^/?${pat}/?$" "$SM_TARGET/.gitignore" 2>/dev/null; then
      sm_say "WARNING: .gitignore excludes '$pat'. Teammates only get this setup if it is committed."
    fi
  done
fi
if [ -f "$SM_TARGET/AGENTS.md.senior-mode" ]; then
  sm_say "NOTE: an AGENTS.md already existed. Merge AGENTS.md.senior-mode into it (the kickoff does this with you); the universal posture lives there."
fi

# ---- 7. summary ------------------------------------------------------------------
echo
sm_say "done. Next: open your agent in $SM_TARGET and paste .senior-mode/KICKOFF-PROMPT.md"
sm_say "      (it verifies the hooks, picks or confirms the stack, fills the placeholders, and merges any .senior-mode files)."
if [ -n "$(printf '%s' "$SM_MERGE_LIST" | tr -d '\n ')" ]; then
  echo
  sm_say "MERGE by hand (existing file kept, new version beside it):"
  printf '%s\n' "$SM_MERGE_LIST" | sed '/^$/d; s/^/    /'
fi
exit 0
