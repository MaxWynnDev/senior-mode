#!/usr/bin/env bash
# Reads the code that was just edited. post-edit-format.sh runs this after
# it formats, with the edited files as arguments, so the two never race
# and an install wired for the formatter gets the check with no new entry.
#
#   post-edit-check.sh <file>...           hook mode: prints the hook JSON
#   post-edit-check.sh --plain <file>...   prints the finding lines (the
#                                          commit gate calls it this way)
#
# Two tiers.
#
# 1. Parse-level, every time, well under a second. It uses whatever the
#    repo's own language already put on the machine and installs nothing:
#      JS / TS   node + lib/check-js.mjs: an import that names nothing, a
#                named import the module does not export, a call to a
#                repo function with the wrong number of arguments, an
#                index that is always one past the end. The repo's own
#                `typescript`, when it is there, adds syntax errors.
#      Python    the project's python + lib/check-py.py: the same four,
#                plus syntax errors from `ast`.
#      Go        gofmt -e          Ruby   ruby -c
#      Shell     bash -n           JSON   node + lib/check-json.mjs
#    A missing runtime skips that language. Nothing is ever installed.
#
# 2. The real checker on the edited files, inside a time budget
#    (SENIOR_MODE_TYPECHECK_BUDGET seconds, default 20). The command comes
#    from SENIOR_MODE_CHECK_FILE_CMD, or `commands.check_file` in the stack
#    profile, or by detection: the repo's own TypeScript on that one file,
#    pyright or mypy when the repo configures one, `go vet` on the file's
#    package, `cargo check`. {file}, {rel} and {dir} in a command are
#    replaced with the path, the repo-relative path and its folder.
#    A check that runs past the budget is stopped and the agent is told to
#    run the full check. After two of those in a session the tier stays
#    off for that session.
#
# SENIOR_MODE_TYPECHECK=off turns tier 2 off (a repo where CI owns the
# typecheck). The repo's own TypeScript still parses the file for syntax
# errors then. SENIOR_MODE_TYPECHECK=no-compiler goes one step further and
# loads nothing from the repo's toolchain: the tokenizer and `ast` checks
# only, for a repo whose policy is that no local process touches
# node_modules. SENIOR_MODE_SYNTAX=off turns the whole hook off.
#
# Findings come back as a PostToolUse block: the edit already happened,
# and the reason lands next to the tool result so the agent fixes it
# before the next step. Fail-open everywhere: a helper that crashes, a
# runtime that is missing or a tool that times out allows.
#
# It also keeps a ledger of the source files edited this turn
# (claude-senior-edited-<session> in the temp dir) when the repo has a
# typecheck command. senior-check-after.sh reads it at Stop and asks for
# the receipt that check.sh writes.

set -u
[ "${SENIOR_MODE_SYNTAX:-on}" = off ] && exit 0

HERE=$(cd "$(dirname "$0")" && pwd)
LIB="$HERE/lib"
[ -f "$LIB/profile.sh" ] || exit 0
# shellcheck source=lib/profile.sh
. "$LIB/profile.sh"

MODE=hook
if [ "${1:-}" = --plain ]; then MODE=plain; shift; fi
[ $# -gt 0 ] || exit 0

T="${TMPDIR:-/tmp}"
ID="${SM_SESSION:-unknown}"
BUDGET="${SENIOR_MODE_TYPECHECK_BUDGET:-20}"
case "$BUDGET" in ''|*[!0-9]*) BUDGET=20 ;; esac
TYPES="${SENIOR_MODE_TYPECHECK:-on}"
# Seconds each parse-level helper may take. They finish in well under one.
# The cap keeps the worst case (two helpers, then the type tier at its
# default budget) inside the 30 seconds this hook is wired with, and the
# commit gate's call inside its 15.
FAST=4
COMPILER=yes
if [ "$TYPES" = no-compiler ]; then TYPES=off; COMPILER=no; fi
[ "$MODE" = plain ] && TYPES=off

JS=(); PY=(); GO=(); RS=(); SH=(); RB=(); JSON=(); SRC=()
for f in "$@"; do
  [ -f "$f" ] || continue
  case "$f" in
    */node_modules/*|*/.git/*|*/dist/*|*/build/*|*/.next/*|*/vendor/*|*/.venv/*|*/venv/*|*/__pycache__/*|*.min.js|*.d.ts) continue ;;
  esac
  case "$f" in
    *.ts|*.tsx|*.mts|*.cts|*.js|*.jsx|*.mjs|*.cjs) JS+=("$f"); SRC+=("$f") ;;
    *.py|*.pyi) PY+=("$f"); SRC+=("$f") ;;
    *.go) GO+=("$f"); SRC+=("$f") ;;
    *.rs) RS+=("$f"); SRC+=("$f") ;;
    *.sh|*.bash) SH+=("$f") ;;
    *.rb) RB+=("$f") ;;
    *.json)
      case "$f" in */tsconfig*.json|*/jsconfig*.json|*/.vscode/*|*/.devcontainer/*|*.code-workspace) ;; *) JSON+=("$f") ;; esac ;;
  esac
done
[ $((${#JS[@]} + ${#PY[@]} + ${#GO[@]} + ${#RS[@]} + ${#SH[@]} + ${#RB[@]} + ${#JSON[@]})) -gt 0 ] || exit 0

# The repo the edited file lives in, which in a worktree is not the
# project dir the session started in.
FIRST="$1"
ROOT=$(git -C "$(dirname "$FIRST")" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$ROOT" ] || ROOT="${SENIOR_MODE_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-${CURSOR_PROJECT_DIR:-${GEMINI_PROJECT_DIR:-.}}}}"
[ -d "$ROOT" ] || exit 0

OUT=$(mktemp 2>/dev/null) || exit 0
TMP=$(mktemp 2>/dev/null) || { rm -f "$OUT"; exit 0; }
trap 'rm -f "$OUT" "$TMP" 2>/dev/null' EXIT
NOTES=""
have() { command -v "$1" >/dev/null 2>&1; }
# Keep only lines shaped like a finding: a helper's stray warning is not one.
keep() { grep -E ':[0-9]+(:[0-9]+)?: ' "$TMP" 2>/dev/null | head -n 30 >> "$OUT" || true; }

STRIKEF="$T/claude-senior-typeslow-$ID"
strikes=0
if [ -f "$STRIKEF" ]; then IFS= read -r strikes < "$STRIKEF" 2>/dev/null || true; fi
case "$strikes" in ''|*[!0-9]*) strikes=0 ;; esac
[ "$strikes" -ge 2 ] && TYPES=off

# rc of a tier-2 run: 124 is a budget kill, anything else is a result.
timed() {
  if [ "$1" -eq 124 ]; then
    strikes=$((strikes + 1))
    printf '%s\n' "$strikes" > "$STRIKEF" 2>/dev/null || true
    NOTES="The type check on this edit did not finish in ${BUDGET}s and was stopped. Run the full check before you call this done: bash $HERE/check.sh"
    [ "$strikes" -ge 2 ] && NOTES="$NOTES (That is two in a row, so the per-edit type check is off for the rest of this session.)"
    return 0
  fi
  [ "$strikes" -gt 0 ] && rm -f "$STRIKEF" 2>/dev/null
  return 1
}

# Run a profile or env check_file command on one file.
custom_check() { # <command> <file>
  local cmd="$1" f="$2" rel dir rc
  # git answers the repo-relative path whatever form the file path took
  # (a symlinked temp dir, a Windows drive path).
  rel="$(git -C "$(dirname "$f")" rev-parse --show-prefix 2>/dev/null || true)$(basename "$f")"
  dir=$(dirname "$rel")
  case "$cmd" in
    *'{file}'*|*'{rel}'*|*'{dir}'*) cmd=${cmd//\{file\}/$f}; cmd=${cmd//\{rel\}/$rel}; cmd=${cmd//\{dir\}/$dir} ;;
    *) cmd="$cmd $f" ;;
  esac
  (cd "$ROOT" && sm_budget "$BUDGET" "$TMP" bash -c "$cmd"); rc=$?
  timed "$rc" && return 0
  [ "$rc" -ne 0 ] && { head -n 20 "$TMP" | cut -c1-400 >> "$OUT"; }
  return 0
}

CUSTOM=""
[ "$TYPES" != off ] && CUSTOM=$(sm_cmd "$ROOT" check_file)

# ---- JavaScript and TypeScript ----------------------------------------------
if [ "${#JS[@]}" -gt 0 ] && have node; then
  sm_budget "$FAST" "$TMP" node "$LIB/check-js.mjs" "$ROOT" "${JS[@]}"; keep
  if [ "$MODE" = hook ]; then
    NEW=()
    for f in "${JS[@]}"; do
      case "$f" in *.ts|*.tsx|*.mts|*.cts) git -C "$(dirname "$f")" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || NEW+=("$f") ;; esac
    done
    if [ "${#NEW[@]}" -gt 0 ] && [ "$COMPILER" = yes ]; then sm_budget "$FAST" "$TMP" node "$LIB/check-ts-types.mjs" "$ROOT" --covered "${NEW[@]}"; keep; fi
  fi
  if [ "$TYPES" = off ]; then
    if [ "$COMPILER" = yes ]; then sm_budget "$FAST" "$TMP" node "$LIB/check-ts-types.mjs" "$ROOT" --syntax "${JS[@]}"; keep; fi
  elif [ -n "$CUSTOM" ]; then
    for f in "${JS[@]}"; do custom_check "$CUSTOM" "$f"; done
  else
    sm_budget "$BUDGET" "$TMP" node "$LIB/check-ts-types.mjs" "$ROOT" "${JS[@]}"; rc=$?
    timed "$rc" || keep
  fi
fi

# ---- Python ------------------------------------------------------------------
if [ "${#PY[@]}" -gt 0 ]; then
  PYBIN=""; PYENV=0
  for c in "$ROOT/.venv/bin/python" "$ROOT/.venv/Scripts/python.exe" "$ROOT/venv/bin/python" "$ROOT/venv/Scripts/python.exe"; do
    if [ -f "$c" ]; then PYBIN="$c"; PYENV=1; break; fi
  done
  if [ -z "$PYBIN" ]; then
    # `python3` on Windows can be a store stub that exists and runs nothing.
    for c in python3 python; do
      if have "$c" && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then PYBIN="$c"; break; fi
    done
  fi
  if [ -n "$PYBIN" ]; then
    export SM_PY_PROJECT_ENV="$PYENV"
    # -B: no __pycache__ left beside the hooks in the user's repo
    sm_budget "$FAST" "$TMP" "$PYBIN" -B "$LIB/check-py.py" "$ROOT" "${PY[@]}"; keep
  fi
  if [ "$TYPES" != off ]; then
    if [ -n "$CUSTOM" ]; then
      for f in "${PY[@]}"; do custom_check "$CUSTOM" "$f"; done
    else
      tool=""
      if [ -f "$ROOT/pyrightconfig.json" ] || grep -q '^\[tool\.pyright' "$ROOT/pyproject.toml" 2>/dev/null; then tool=pyright
      elif [ -f "$ROOT/mypy.ini" ] || [ -f "$ROOT/.mypy.ini" ] || grep -q '^\[tool\.mypy' "$ROOT/pyproject.toml" 2>/dev/null || grep -q '^\[mypy' "$ROOT/setup.cfg" 2>/dev/null; then tool=mypy
      fi
      bin=""
      if [ -n "$tool" ]; then
        for c in "$ROOT/.venv/bin/$tool" "$ROOT/.venv/Scripts/$tool.exe"; do [ -f "$c" ] && { bin="$c"; break; }; done
        [ -n "$bin" ] || { have "$tool" && bin="$tool"; }
      fi
      if [ -n "$bin" ]; then
        (cd "$ROOT" && sm_budget "$BUDGET" "$TMP" "$bin" "${PY[@]}"); rc=$?
        if ! timed "$rc" && [ "$rc" -ne 0 ]; then grep -E 'error' "$TMP" 2>/dev/null | head -n 20 | cut -c1-400 >> "$OUT" || true; fi
      fi
    fi
  fi
fi

# ---- Go, Rust ----------------------------------------------------------------
if [ "${#GO[@]}" -gt 0 ]; then
  if have gofmt; then
    for f in "${GO[@]}"; do gofmt -e "$f" > /dev/null 2>> "$OUT" || true; done
  fi
  if [ "$TYPES" != off ]; then
    for f in "${GO[@]}"; do
      if [ -n "$CUSTOM" ]; then custom_check "$CUSTOM" "$f"
      elif have go && [ -f "$ROOT/go.mod" ]; then
        (cd "$(dirname "$f")" && sm_budget "$BUDGET" "$TMP" go vet .); rc=$?
        if ! timed "$rc" && [ "$rc" -ne 0 ]; then grep -vE '^#' "$TMP" 2>/dev/null | head -n 20 | cut -c1-400 >> "$OUT" || true; fi
      fi
    done
  fi
fi
if [ "${#RS[@]}" -gt 0 ] && [ "$TYPES" != off ]; then
  if [ -n "$CUSTOM" ]; then
    for f in "${RS[@]}"; do custom_check "$CUSTOM" "$f"; done
  elif have cargo && [ -f "$ROOT/Cargo.toml" ]; then
    (cd "$ROOT" && sm_budget "$BUDGET" "$TMP" cargo check -q --message-format=short); rc=$?
    if ! timed "$rc" && [ "$rc" -ne 0 ]; then grep -E 'error' "$TMP" 2>/dev/null | head -n 20 | cut -c1-400 >> "$OUT" || true; fi
  fi
fi

# ---- Shell, Ruby, JSON -------------------------------------------------------
if [ "${#SH[@]}" -gt 0 ]; then
  for f in "${SH[@]}"; do bash -n "$f" 2>> "$OUT" || true; done
fi
if [ "${#RB[@]}" -gt 0 ] && have ruby; then
  for f in "${RB[@]}"; do ruby -c "$f" > /dev/null 2>> "$OUT" || true; done
fi
if [ "${#JSON[@]}" -gt 0 ] && have node; then
  sm_budget "$FAST" "$TMP" node "$LIB/check-json.mjs" "${JSON[@]}"; keep
fi

# ---- the ledger the Stop hook reads -------------------------------------------
if [ "$MODE" = hook ] && [ "$TYPES" != off ] && [ "${#SRC[@]}" -gt 0 ] && [ -n "$(sm_cmd "$ROOT" typecheck)" ]; then
  LEDGER="$T/claude-senior-edited-$ID"
  if [ ! -s "$LEDGER" ]; then
    GD=$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)
    [ -n "$GD" ] && printf 'receipt=%s\ncheck=%s\n' "$GD/senior-mode/receipt-typecheck" "$HERE/check.sh" > "$LEDGER" 2>/dev/null
  fi
  [ -s "$LEDGER" ] && printf '%s\n' "${SRC[@]}" >> "$LEDGER" 2>/dev/null
fi

# ---- report --------------------------------------------------------------------
if [ "$MODE" = plain ]; then
  [ -s "$OUT" ] && head -n 40 "$OUT" | cut -c1-400
  exit 0
fi
if [ -s "$OUT" ]; then
  BODY=$(head -n 40 "$OUT" | cut -c1-400)
  REASON="[SENIOR CHECK | CODE] The file you just edited has problems these checks can name:

$BODY

Fix them now, before the next step. If a line is wrong (an import that does resolve, a call the check misread), say which one and why, then carry on. These checks read the edited file only. They are not the full typecheck."
  [ -n "$NOTES" ] && REASON="$REASON

$NOTES"
  printf '{\n  "decision": "block",\n  "reason": "%s"\n}\n' "$(sm_text_to_json "$REASON")"
elif [ -n "$NOTES" ]; then
  printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "PostToolUse",\n    "additionalContext": "%s"\n  }\n}\n' "$(sm_text_to_json "[SENIOR CHECK | CODE] $NOTES")"
fi
exit 0
