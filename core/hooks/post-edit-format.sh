#!/usr/bin/env bash
# Auto-format the just-edited file. Wired on PostToolUse / Write|Edit.
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
  Write|Edit) ;;
  *) exit 0 ;;
esac

FILE=$(printf '%s' "$FLAT" | sed -nE 's/.*"file_path"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p')
[ -n "$FILE" ] || exit 0
# JSON-unescape: Windows paths arrive as C:\\Users\\... -> C:/Users/...
FILE=$(printf '%s' "$FILE" | sed 's/\\\\/\//g')
[ -f "$FILE" ] || exit 0

ROOT="${SENIOR_MODE_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-${CURSOR_PROJECT_DIR:-${GEMINI_PROJECT_DIR:-.}}}}"
has_any() { local c; for c in "$@"; do [ -f "$ROOT/$c" ] && return 0; done; return 1; }
run_quiet() { "$@" >/dev/null 2>&1 || true; }

# 1. Explicit project opt-in.
FORMAT_CMD="${SENIOR_MODE_FORMAT_CMD:-${CLAUDE_FORMAT_CMD:-}}"
if [ -n "$FORMAT_CMD" ]; then
  # shellcheck disable=SC2086  # word-split is the documented contract
  $FORMAT_CMD "$FILE" >/dev/null 2>&1 || true
  exit 0
fi

# 2. Auto-detect.
case "$FILE" in
  *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs|*.json|*.jsonc|*.css|*.scss|*.less|*.md|*.mdx|*.html|*.vue|*.svelte|*.astro|*.yml|*.yaml|*.graphql)
    if has_any deno.json deno.jsonc && command -v deno >/dev/null 2>&1; then
      run_quiet deno fmt "$FILE"; exit 0
    fi
    if has_any biome.json biome.jsonc; then
      if [ -f "$ROOT/node_modules/.bin/biome" ]; then
        run_quiet "$ROOT/node_modules/.bin/biome" format --write "$FILE"; exit 0
      elif command -v biome >/dev/null 2>&1; then
        run_quiet biome format --write "$FILE"; exit 0
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
    exit 0
    ;;
  *.py|*.pyi)
    if { has_any ruff.toml .ruff.toml || { [ -f "$ROOT/pyproject.toml" ] && grep -q '^\[tool\.ruff' "$ROOT/pyproject.toml" 2>/dev/null; }; } \
       && command -v ruff >/dev/null 2>&1; then
      run_quiet ruff format "$FILE"; exit 0
    fi
    if [ -f "$ROOT/pyproject.toml" ] && grep -q '^\[tool\.black' "$ROOT/pyproject.toml" 2>/dev/null \
       && command -v black >/dev/null 2>&1; then
      run_quiet black -q "$FILE"; exit 0
    fi
    exit 0
    ;;
  *.go)
    command -v gofmt >/dev/null 2>&1 && run_quiet gofmt -w "$FILE"
    exit 0
    ;;
  *.rs)
    if has_any Cargo.toml && command -v rustfmt >/dev/null 2>&1; then
      run_quiet rustfmt --edition 2021 "$FILE"
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
