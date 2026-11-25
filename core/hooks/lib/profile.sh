#!/usr/bin/env bash
# Shared lookup: which command does this repo use to typecheck, to check
# one file, to run its tests? Sourced by post-edit-check.sh, check.sh and
# boundary-probe.sh. Pure bash, no jq.
#
#   sm_cmd <root> <key>     prints the command, or nothing
#
# Keys: typecheck, check_file, test, test_related.
#
# Resolution order, first hit wins:
#   1. the environment: SENIOR_MODE_TYPECHECK_CMD, SENIOR_MODE_CHECK_FILE_CMD,
#      SENIOR_MODE_TEST_CMD, SENIOR_MODE_TEST_RELATED_CMD
#   2. the installed stack profile: .senior-mode/stacks/<name>/profile.json,
#      "commands" -> "<key>". The profile is the one named in
#      .senior-mode/stacks/ACTIVE, or the only profile folder that holds a
#      WORKFLOW.md (install.sh copies that file for the chosen profile only).
#   3. for typecheck alone, the repo's own manifest: a package.json script
#      named typecheck, type-check or check-types, run with the package
#      manager its lockfile names.
#
# A value still carrying a <placeholder> is treated as unset. Nothing here
# guesses a test command: a guessed test script can be a watcher that
# never exits.

sm_json_string() { # <file> <key> -> the first string value of "key", unescaped
  [ -f "$1" ] || return 0
  tr -d '\n\r' < "$1" | sed -nE 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p' | sed 's/\\"/"/g; s/\\\\/\\/g'
}

sm_profile_file() { # <root> -> path of the active profile.json, or nothing
  local root="$1" dir name="" found="" n=0 f
  dir="$root/.senior-mode/stacks"
  [ -d "$dir" ] || return 0
  if [ -f "$dir/ACTIVE" ]; then
    IFS= read -r name < "$dir/ACTIVE" || true
    name=${name%$'\r'}
    [ -n "$name" ] && [ -f "$dir/$name/profile.json" ] && { printf '%s' "$dir/$name/profile.json"; return 0; }
  fi
  for f in "$dir"/*/WORKFLOW.md; do
    [ -f "$f" ] || continue
    found="${f%/WORKFLOW.md}/profile.json"; n=$((n + 1))
  done
  [ "$n" -eq 1 ] && [ -f "$found" ] && printf '%s' "$found"
  return 0
}

sm_cmd() { # <root> <key>
  local root="$1" key="$2" v="" pf script pm
  case "$key" in
    typecheck)    v="${SENIOR_MODE_TYPECHECK_CMD:-}" ;;
    check_file)   v="${SENIOR_MODE_CHECK_FILE_CMD:-}" ;;
    test)         v="${SENIOR_MODE_TEST_CMD:-}" ;;
    test_related) v="${SENIOR_MODE_TEST_RELATED_CMD:-}" ;;
  esac
  if [ -z "$v" ]; then
    pf=$(sm_profile_file "$root")
    [ -n "$pf" ] && v=$(sm_json_string "$pf" "$key")
  fi
  case "$v" in *'<'*'>'*) v="" ;; esac
  if [ -z "$v" ] && [ "$key" = typecheck ] && [ -f "$root/package.json" ]; then
    for script in typecheck type-check check-types; do
      if tr -d '\n\r' < "$root/package.json" | grep -qE '"scripts"[[:space:]]*:[[:space:]]*\{[^}]*"'"$script"'"[[:space:]]*:'; then
        pm=npm
        [ -f "$root/pnpm-lock.yaml" ] && pm=pnpm
        [ -f "$root/yarn.lock" ] && pm=yarn
        { [ -f "$root/bun.lock" ] || [ -f "$root/bun.lockb" ]; } && pm=bun
        v="$pm run $script"
        break
      fi
    done
  fi
  printf '%s' "$v"
}

# sm_budget <seconds> <output-file> <command...>
# Runs the command with stdout and stderr in the file, and kills it when
# the budget runs out. Returns the command's exit code, or 124 on a kill.
# Pure bash: macOS ships no `timeout`.
sm_budget() {
  local secs="$1" out="$2" pid ticks=0 limit
  shift 2
  limit=$((secs * 5))
  "$@" > "$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$limit" ]; then
      kill "$pid" 2>/dev/null
      sleep 0.2
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.2
    ticks=$((ticks + 1))
  done
  wait "$pid"
}

# sm_text_to_json <text> -> the body of a JSON string. Double quotes become
# single quotes: the Cursor and Gemini shims re-embed hook text in their
# own JSON and expect none.
sm_text_to_json() {
  local s="$1" q="'"
  s=${s//\\/\\\\}
  s=${s//\"/$q}
  s=${s//$'\t'/ }
  s=${s//$'\r'/}
  s=${s//$'\n'/\\n}
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}
