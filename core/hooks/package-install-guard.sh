#!/usr/bin/env bash
# Package install guard (Claude Code hook contract). Wired on PreToolUse / Bash.
#
# An agent that invents an import often goes on to install the package it
# invented. Two things can happen. The name does not exist and the install
# fails, after which the agent tries the next plausible spelling. Or the
# name does exist, because somebody registered the spelling agents keep
# inventing, and the install runs a stranger's code.
#
# So before a package this repo has never used gets installed, this looks
# the name up:
#   npm   (npm / pnpm / yarn / bun, install / i / add)
#         https://api.npmjs.org/downloads/point/last-week/<name>
#         404           -> deny: no such package
#         under the floor of weekly downloads (SENIOR_MODE_INSTALL_MIN_DOWNLOADS,
#         default 300)  -> deny once: show where the name comes from
#   PyPI  (pip / pip3 / python -m pip install, uv add, uv pip install,
#         poetry add, pipx install)
#         HEAD https://pypi.org/pypi/<name>/json
#         404           -> deny: no such package
#
# A name already in the repo's manifest or lockfile is not looked up. Each
# name is denied at most once per session: run the same command again and
# it goes through, so a wrong verdict costs one round.
#
# The lookup sends the package name, and nothing else, to the registry the
# install itself is about to contact. It needs curl and a network. Without
# either, or on any answer it does not recognise, it allows.
# SENIOR_MODE_INSTALL_LOOKUP=off turns it off.

set -u

INPUT=$(cat)
FLAT=$(printf '%s' "$INPUT" | tr -d '\n')
CMD=$(printf '%s' "$FLAT" | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p')

allow() { printf '{}\n'; exit 0; }
[ "${SENIOR_MODE_INSTALL_LOOKUP:-on}" = off ] && allow
[ -n "$CMD" ] || allow
case "$CMD" in *install*|*" add "*|*" i "*) ;; *) allow ;; esac
command -v curl >/dev/null 2>&1 || allow

SESSION_ID=$(printf '%s' "$FLAT" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
SEEN="${TMPDIR:-/tmp}/claude-senior-pkg-${SESSION_ID:-unknown}"
ROOT="${SENIOR_MODE_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-${CURSOR_PROJECT_DIR:-${GEMINI_PROJECT_DIR:-.}}}}"
FLOOR="${SENIOR_MODE_INSTALL_MIN_DOWNLOADS:-300}"
case "$FLOOR" in ''|*[!0-9]*) FLOOR=300 ;; esac

NPM_VALUE_FLAGS=' --registry --prefix -C --dir --filter -F --workspace --tag --cache --userconfig '
PIP_VALUE_FLAGS=' -r --requirement -c --constraint -e --editable -i --index-url --extra-index-url -f --find-links -t --target --prefix --root --python --group -G --extra '

# Is the name already part of this repo? Then it is not a new name.
known() { # <eco> <name>
  local eco="$1" name="$2" pat files f d
  pat=${name//./\\.}
  if [ "$eco" = npm ]; then files="package.json pnpm-lock.yaml package-lock.json yarn.lock bun.lock"
  else files="pyproject.toml requirements.txt requirements-dev.txt uv.lock poetry.lock Pipfile Pipfile.lock setup.cfg setup.py"; fi
  for f in $files; do
    for d in . "$ROOT"; do
      [ -f "$d/$f" ] || continue
      grep -qiE "(^|[^A-Za-z0-9_.@/-])${pat}(\$|[^A-Za-z0-9_.-])" "$d/$f" 2>/dev/null && return 0
    done
  done
  return 1
}

VERDICT=""   # the first problem found: "<kind>|<eco>|<name>|<detail>"
LOOKUPS=0
lookup() { # <eco> <name>
  local eco="$1" name="$2" out code body n
  [ -n "$VERDICT" ] && return 0
  [ "$LOOKUPS" -ge 2 ] && return 0   # two lookups at 4 seconds each fit the hook's 10
  grep -qxF "$eco:$name" "$SEEN" 2>/dev/null && return 0
  known "$eco" "$name" && return 0
  LOOKUPS=$((LOOKUPS + 1))
  if [ "$eco" = npm ]; then
    out=$(curl -s --max-time 4 -w '\n%{http_code}' "https://api.npmjs.org/downloads/point/last-week/$name" 2>/dev/null || true)
    code=${out##*$'\n'}
    body=${out%$'\n'*}
    if [ "$code" = 404 ]; then VERDICT="missing|npm|$name|"
    elif [ "$code" = 200 ]; then
      n=$(printf '%s' "$body" | sed -nE 's/.*"downloads"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p')
      case "$n" in ''|*[!0-9]*) return 0 ;; esac
      [ "$n" -lt "$FLOOR" ] && VERDICT="rare|npm|$name|$n"
    fi
  else
    code=$(curl -s -I --max-time 4 -o /dev/null -w '%{http_code}' "https://pypi.org/pypi/$name/json" 2>/dev/null || true)
    [ "$code" = 404 ] && VERDICT="missing|PyPI|$name|"
  fi
  return 0
}

# One shell segment at a time. The command is still JSON-escaped: a line
# break is a backslash and an n, a quote is a backslash and a quote.
SEGMENTS=$(printf '%s' "$CMD" | awk '{ gsub(/\\n|&&|\|\||;|\|/, "\n"); print }')
while IFS= read -r seg; do
  seg=${seg//\\\"/}
  seg=${seg//\'/}
  set -f
  # shellcheck disable=SC2086  # word-splitting is the tokenizer here
  set -- $seg
  set +f
  while [ $# -gt 0 ]; do
    case "$1" in sudo|command|env|*=*) shift ;; *) break ;; esac
  done
  [ $# -ge 2 ] || continue
  tool="$1"; shift
  eco=""; flags=""
  case "$tool" in
    npm|pnpm|yarn|bun) eco=npm; flags="$NPM_VALUE_FLAGS"; verbs=' install i add ' ;;
    pip|pip3|pipx)     eco=pypi; flags="$PIP_VALUE_FLAGS"; verbs=' install ' ;;
    poetry)            eco=pypi; flags="$PIP_VALUE_FLAGS"; verbs=' add ' ;;
    uv)                eco=pypi; flags="$PIP_VALUE_FLAGS"; verbs=' add install ' ;;
    python|python3)    [ "${1:-}" = -m ] && [ "${2:-}" = pip ] || continue
                       shift 2; eco=pypi; flags="$PIP_VALUE_FLAGS"; verbs=' install ' ;;
    *) continue ;;
  esac
  # the verb: first word that is not a flag (or a flag's value)
  verb=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -*) case "$flags" in *" $1 "*) shift ;; esac; shift ;;
      pip) shift ;;   # uv pip install
      *) verb="$1"; shift; break ;;
    esac
  done
  case "$verbs" in *" $verb "*) ;; *) continue ;; esac
  [ "$tool" = yarn ] && [ "$verb" != add ] && continue
  while [ $# -gt 0 ]; do
    tok="$1"; shift
    case "$tok" in
      -*) case "$flags" in *" $tok "*) [ $# -gt 0 ] && shift ;; esac; continue ;;
      .*|/*|~*|*://*|git+*|*:*|*.tgz|*.whl|*.tar.gz|*.zip|*'$'*|*'`'*|*'('*) continue ;;
    esac
    if [ "$eco" = npm ]; then
      case "$tok" in
        @*/*) rest=${tok#@}; name="@${rest%%@*}" ;;
        @*)   continue ;;
        */*)  continue ;;
        *)    name=${tok%%@*} ;;
      esac
      case "$name" in *[!a-zA-Z0-9@/._~-]*|'') continue ;; esac
    else
      name=${tok%%[=<>!~\[;]*}
      case "$name" in *[!a-zA-Z0-9._-]*|'') continue ;; esac
    fi
    lookup "$eco" "$name"
  done
done <<EOF
$SEGMENTS
EOF

[ -n "$VERDICT" ] || allow

KIND=${VERDICT%%|*}; R=${VERDICT#*|}
REG=${R%%|*}; R=${R#*|}
NAME=${R%%|*}; DETAIL=${R#*|}
[ "$REG" = PyPI ] && ECO=pypi || ECO=npm
printf '%s\n' "$ECO:$NAME" >> "$SEEN" 2>/dev/null || true

if [ "$KIND" = missing ]; then
  REASON="BLOCKED: there is no package named $NAME on $REG, so the name is probably invented. Find the real one first (the import you are trying to satisfy, the library's own docs), then install that. Nothing was installed."
else
  REASON="BLOCKED once: $NAME exists on $REG and had $DETAIL downloads last week. A name that quiet is how a look-alike package gets installed. Say where the name comes from (the docs or the repo that tell you to install it). If it is the one you mean, run the same command again and it goes through."
fi
printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "PreToolUse",\n    "permissionDecision": "deny",\n    "permissionDecisionReason": "%s"\n  }\n}\n' "$REASON"
exit 0
