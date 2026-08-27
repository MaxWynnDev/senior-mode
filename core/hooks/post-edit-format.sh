#!/usr/bin/env bash
# Auto-format the just-edited file. Wired on PostToolUse with each agent's
# edit-tool matcher; the tool gate below accepts every adapter's native
# edit-tool vocabulary, not just Claude Code's Write|Edit. The harness only
# ever spoke Claude names, which is how the drift stayed invisible.
#
# WHY: the agent writes well-formatted code most of the time; the last few
# percent is what fails CI on a formatting step. A deterministic formatter
# after every edit closes that gap without burning model attention on
# style.
#
# Resolution order:
#   1. $CLAUDE_FORMAT_CMD, when set: runs `$CLAUDE_FORMAT_CMD <file>`.
#      The variable is word-split on purpose so it can carry args, e.g.
#        CLAUDE_FORMAT_CMD="npx prettier --write"
#        CLAUDE_FORMAT_CMD="ruff format"
#      Set it in .claude/settings.json "env" or your shell profile.
#   2. Auto-detect by extension, config presence, and an available binary:
#        JS/TS/CSS/MD/JSON/YAML  biome (biome.json[c] + local biome bin)
#                                else prettier (config + local prettier bin)
#        Python                  ruff (ruff.toml or [tool.ruff] in pyproject)
#                                else black ([tool.black] in pyproject)
#        Go                      gofmt (always canonical, no config needed)
#        Rust                    rustfmt (Cargo.toml present)
#        Deno projects           deno fmt (deno.json[c] present)
#      Local project binaries are preferred over PATH ones; a config file
#      signals intent, so a formatter is never imposed on a repo that did
#      not adopt it (gofmt is the one exception: it is the language's own
#      standard).
#   3. Otherwise: silent no-op.
#
# Guarantees: never blocks the turn, never touches any file except the
# one just written, always exits 0. Fail-open everywhere: a broken
# formatter must never break the edit that already succeeded.

set -u

INPUT=$(cat)
FLAT=$(printf '%s' "$INPUT" | tr -d '\n')

TOOL=$(printf '%s' "$FLAT" | sed -nE 's/.*"tool_name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
case "$TOOL" in
  Write|Edit) ;;                    # Claude Code; Copilot and Codex configs alias these
  Create|ApplyPatch) ;;             # Factory Droid
  apply_patch|write|edit) ;;        # Codex and Devin payload names
  save-file|str-replace-editor) ;;  # Augment
  *) exit 0 ;;
esac

FILE=$(printf '%s' "$FLAT" | sed -nE 's/.*"file_path"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p')
# Augment's tool_input carries the file under "path"
[ -n "$FILE" ] || FILE=$(printf '%s' "$FLAT" | sed -nE 's/.*"path"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p')
# JSON-unescape: Windows paths arrive as C:\\Users\\... -> C:/Users/...
FILE=$(printf '%s' "$FILE" | sed 's/\\\\/\//g')

ROOT="${SENIOR_MODE_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-${CURSOR_PROJECT_DIR:-${GEMINI_PROJECT_DIR:-${FACTORY_PROJECT_DIR:-${DEVIN_PROJECT_DIR:-${AUGMENT_PROJECT_DIR:-.}}}}}}}"
has_any() { local c; for c in "$@"; do [ -f "$ROOT/$c" ] && return 0; done; return 1; }
run_quiet() { "$@" >/dev/null 2>&1 || true; }
FORMAT_CMD="${SENIOR_MODE_FORMAT_CMD:-${CLAUDE_FORMAT_CMD:-}}"

format_one() {
  local FILE="$1"

  # 1. Explicit project opt-in.
  if [ -n "$FORMAT_CMD" ]; then
    # shellcheck disable=SC2086  # word-split is the documented contract
    $FORMAT_CMD "$FILE" >/dev/null 2>&1 || true
    return 0
  fi

  # 2. Auto-detect.
  case "$FILE" in
    *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs|*.json|*.jsonc|*.css|*.scss|*.less|*.md|*.mdx|*.html|*.vue|*.svelte|*.astro|*.yml|*.yaml|*.graphql)
      if has_any deno.json deno.jsonc && command -v deno >/dev/null 2>&1; then
        run_quiet deno fmt "$FILE"; return 0
      fi
      if has_any biome.json biome.jsonc; then
        if [ -f "$ROOT/node_modules/.bin/biome" ]; then
          run_quiet "$ROOT/node_modules/.bin/biome" format --write "$FILE"; return 0
        elif command -v biome >/dev/null 2>&1; then
          run_quiet biome format --write "$FILE"; return 0
        fi
      fi
      has_cfg=no
      if has_any .prettierrc .prettierrc.json .prettierrc.yml .prettierrc.yaml \
                 .prettierrc.js .prettierrc.cjs .prettierrc.mjs .prettierrc.toml \
                 prettier.config.js prettier.config.cjs prettier.config.mjs prettier.config.ts; then
        has_cfg=yes
      elif [ -f "$ROOT/package.json" ] && grep -q '"prettier"' "$ROOT/package.json" 2>/dev/null; then
        has_cfg=yes
      fi
      if [ "$has_cfg" = yes ] && [ -f "$ROOT/node_modules/.bin/prettier" ]; then
        # --ignore-unknown: if prettier does not own this file after all, no-op.
        run_quiet "$ROOT/node_modules/.bin/prettier" --write --ignore-unknown "$FILE"
      fi
      return 0
      ;;
    *.py|*.pyi)
      if { has_any ruff.toml .ruff.toml || { [ -f "$ROOT/pyproject.toml" ] && grep -q '^\[tool\.ruff' "$ROOT/pyproject.toml" 2>/dev/null; }; } \
         && command -v ruff >/dev/null 2>&1; then
        run_quiet ruff format "$FILE"; return 0
      fi
      if [ -f "$ROOT/pyproject.toml" ] && grep -q '^\[tool\.black' "$ROOT/pyproject.toml" 2>/dev/null \
         && command -v black >/dev/null 2>&1; then
        run_quiet black -q "$FILE"; return 0
      fi
      return 0
      ;;
    *.go)
      command -v gofmt >/dev/null 2>&1 && run_quiet gofmt -w "$FILE"
      return 0
      ;;
    *.rs)
      if has_any Cargo.toml && command -v rustfmt >/dev/null 2>&1; then
        run_quiet rustfmt --edition 2021 "$FILE"
      fi
      return 0
      ;;
    *) return 0 ;;
  esac
}

if [ -n "$FILE" ]; then
  [ -f "$FILE" ] && format_one "$FILE"
  exit 0
fi

# Codex and Devin report file edits as apply_patch: there is no file_path,
# the whole patch rides in tool_input.command. The envelope names its files
# on "*** Add File:" / "*** Update File:" / "*** Move to:" lines; paths are
# always relative and hook commands run from the session cwd, so they
# resolve as-is. Anything that does not exist after the patch is skipped.
case "$TOOL" in apply_patch|ApplyPatch) ;; *) exit 0 ;; esac
printf '%s' "$FLAT" | awk '
  {
    s = $0; pat = "\"command\"[[:space:]]*:[[:space:]]*\"";
    if (!match(s, pat)) exit;
    s = substr(s, RSTART + RLENGTH); out = "";
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1);
      if (c == "\\") {
        d = substr(s, i + 1, 1); i++;
        if (d == "n") out = out "\n";
        else if (d == "t") out = out "\t";
        else if (d == "r") continue;
        else out = out d;
      } else if (c == "\"") break;
      else out = out c;
    }
    n = split(out, lines, "\n");
    for (j = 1; j <= n; j++) {
      l = lines[j];
      if (l ~ /^\*\*\* (Add|Update) File: /) { sub(/^\*\*\* (Add|Update) File: /, "", l); print l }
      else if (l ~ /^\*\*\* Move to: /)      { sub(/^\*\*\* Move to: /, "", l); print l }
    }
  }' | while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$f" ] && format_one "$f"
done
exit 0
