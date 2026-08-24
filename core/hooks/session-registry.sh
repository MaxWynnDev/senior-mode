#!/usr/bin/env bash
# PRINCIPLES: max-lines-exception: single-purpose library + CLI that
# session-tree-guard.sh sources; a split would duplicate the load path
# and the fork-free helpers. Roughly 60 of these lines are the rationale.
#
# Multi-session git-tree awareness for coding agents.
#
# WHY THIS EXISTS: when several agent sessions run at once in ONE
# shared checkout (same folder, same branch, no worktrees), their edits
# and commits mix in the single working tree. The tree drifts, in-flight
# work tangles with already-committed work, and recovery usually costs a
# hard reset. This makes every concurrent session aware of the others and
# steers later ones into their own git worktree before they commit.
#
# THE MODEL:
#   - Every live session registers a small heartbeat file so EVERY other
#     session knows who else is active, on what working tree, branch, and
#     HEAD, with zero need for the user to mention it.
#   - The FIRST (earliest) session in a checkout is the "incumbent" and
#     owns that working tree: it keeps committing/pushing normally.
#   - Any LATER session that lands in the same checkout is told to move
#     into its own git worktree (its own branch off the mainline) before
#     it commits. session-tree-guard.sh enforces this by blocking
#     commit/push from a shared checkout for non-incumbents.
#   - Sessions in separate worktrees share the repo's object store but NOT
#     the working tree, so they never tangle. They coordinate only at the
#     final push (fetch + rebase + push), which git already serialises.
#
# WHERE STATE LIVES: $(git --git-common-dir)/claude-sessions/. That dir is
# shared by the main checkout AND every linked worktree (one .git), is
# per-clone, and lives inside .git so it is never tracked, never shown by
# `git status`, and needs no .gitignore entry.
#
# This file is BOTH a CLI (register | touch | unregister | list) AND a
# sourceable library (session-tree-guard.sh sources it). The CLI dispatch
# at the bottom only runs when the file is executed directly.
#
# Liveness: `unregister` (wired on SessionEnd) removes the entry on a clean
# exit; a timestamp TTL (CLAUDE_SESSION_TTL_MIN, default 45) prunes the
# entry of a crashed session so it can never wedge the guard. PID is
# recorded for diagnostics only (Windows/MSYS PID liveness is not
# portable, so it is never trusted).
#
# Mainline branch: detected from origin's HEAD (`git symbolic-ref
# refs/remotes/origin/HEAD`), overridable with SENIOR_MODE_MAINLINE, and
# falling back to `main`. So `master` and `trunk` repos get correct prose
# without editing this file.
#
# PERFORMANCE: this runs on every prompt via Git Bash on Windows, where
# each process spawn costs 50-150ms. The helpers are pure bash (no
# grep/sed/date forks) on purpose; a fork-per-field version took seconds
# per touch and timed out the hook. Keep new code fork-free.
#
# Fail-open everywhere: not a git repo, git missing, or any error -> stay
# silent and never block. A noisy false reminder is fine; a broken git is
# not.

set -u

TTL_MIN="${SENIOR_MODE_SESSION_TTL_MIN:-${CLAUDE_SESSION_TTL_MIN:-45}}"

# ---------------------------------------------------------------------------
# Library (no side effects at source time)
# ---------------------------------------------------------------------------

reg_now() { printf '%s' "${EPOCHSECONDS:-$(date +%s)}"; }

# Escape a value for embedding inside a JSON string, and strip newlines.
reg_json_escape() {
  local s="${1//$'\r'/}"
  s="${s//$'\n'/}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# Pull a string field out of a flattened (newline-stripped) JSON payload.
reg_extract() {
  local pat="\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
  [[ "$2" =~ $pat ]] && printf '%s' "${BASH_REMATCH[1]}"
}

# Normalise a payload path: JSON \\ -> \ , then all backslashes -> / so a
# Windows cwd ("C:\\Users\\..") becomes "C:/Users/.." which `git -C`
# accepts and which compares cleanly across sessions.
reg_norm_path() {
  local s="${1//\\\\/\/}"
  printf '%s' "${s//\\/\/}"
}

# The mainline branch name: override, else origin's HEAD, else main.
reg_mainline() {
  local base="${1:-.}" m=''
  if [ -n "${SENIOR_MODE_MAINLINE:-}" ]; then printf '%s' "$SENIOR_MODE_MAINLINE"; return 0; fi
  m=$(git -C "$base" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) || m=''
  m="${m#origin/}"
  printf '%s' "${m:-main}"
}

# Resolve repo identity from a base dir. Sets globals and returns 1 if the
# base is not inside a git repo (or git is unavailable).
#   REG_TOP    working-tree root, git-normalised (forward slash)
#   REG_COMMON absolute shared git dir (same for main + all worktrees)
#   REG_DIR    the session registry dir (created)
#   REG_INWT   yes|no  -- am I in a linked worktree (not the main one)?
#   REG_BRANCH current branch (or HEAD when detached)
#   REG_HEAD   short HEAD sha
#   REG_MAIN   mainline branch name
reg_resolve() {
  local base="$1"
  [ -n "$base" ] || base="${SENIOR_MODE_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-${CURSOR_PROJECT_DIR:-${GEMINI_PROJECT_DIR:-.}}}}"
  command -v git >/dev/null 2>&1 || return 1
  # One combined rev-parse for the three paths (each git spawn is ~120ms
  # on Windows), plus one optional call for HEAD info (tolerates an
  # empty/unborn repo).
  local paths gd head_info
  paths=$(git -C "$base" rev-parse --path-format=absolute --show-toplevel --git-common-dir --git-dir 2>/dev/null) || return 1
  {
    IFS= read -r REG_TOP
    IFS= read -r REG_COMMON
    IFS= read -r gd
  } <<< "$paths"
  [ -n "$REG_TOP" ] || return 1
  [ -n "$REG_COMMON" ] || return 1
  if [ "$gd" = "$REG_COMMON" ]; then REG_INWT=no; else REG_INWT=yes; fi
  REG_BRANCH=''; REG_HEAD=''
  if head_info=$(git -C "$base" rev-parse HEAD --abbrev-ref HEAD 2>/dev/null); then
    {
      IFS= read -r REG_HEAD
      IFS= read -r REG_BRANCH
    } <<< "$head_info"
    REG_HEAD="${REG_HEAD:0:8}"
  fi
  REG_MAIN=$(reg_mainline "$base")
  REG_DIR="$REG_COMMON/claude-sessions"
  mkdir -p "$REG_DIR" 2>/dev/null || return 1
  return 0
}

reg_getval() {
  local line val=''
  [ -r "$2" ] || { printf ''; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$1="*) val="${line#*=}"; break;; esac
  done < "$2"
  printf '%s' "$val"
}

# Load every field of one session file into REG_F_* globals in a single
# pass with zero forks.
reg_load() {
  REG_F_sid='' REG_F_toplevel='' REG_F_branch='' REG_F_inwt=''
  REG_F_started='' REG_F_seen='' REG_F_peers=''
  local line
  [ -r "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      sid=*)      REG_F_sid="${line#sid=}";;
      toplevel=*) REG_F_toplevel="${line#toplevel=}";;
      branch=*)   REG_F_branch="${line#branch=}";;
      inwt=*)     REG_F_inwt="${line#inwt=}";;
      started=*)  REG_F_started="${line#started=}";;
      seen=*)     REG_F_seen="${line#seen=}";;
      peers=*)    REG_F_peers="${line#peers=}";;
    esac
  done < "$1"
}

# Drop entries whose heartbeat is older than the TTL (or malformed), plus
# orphaned tmp files from interrupted writes.
reg_prune() {
  local ttl=$(( TTL_MIN * 60 )) n f
  n=$(reg_now)
  for f in "$REG_DIR"/*.session; do
    [ -e "$f" ] || continue
    reg_load "$f"
    case "$REG_F_seen" in ''|*[!0-9]*) rm -f "$f"; continue;; esac
    [ $(( n - REG_F_seen )) -le "$ttl" ] || rm -f "$f"
  done
  for f in "$REG_DIR"/*.session.tmp.*; do
    [ -e "$f" ] || continue
    reg_load "$f"
    case "$REG_F_seen" in ''|*[!0-9]*) continue;; esac
    [ $(( n - REG_F_seen )) -le "$ttl" ] || rm -f "$f"
  done
}

# Live sessions whose working tree == mine (the tangle set; includes self).
# Emits: started<TAB>sid<TAB>branch<TAB>seen<TAB>inwt
reg_same_tree() {
  local ttl=$(( TTL_MIN * 60 )) n f started
  n=$(reg_now)
  for f in "$REG_DIR"/*.session; do
    [ -e "$f" ] || continue
    reg_load "$f"
    [ "$REG_F_toplevel" = "$REG_TOP" ] || continue
    case "$REG_F_seen" in ''|*[!0-9]*) continue;; esac
    [ $(( n - REG_F_seen )) -le "$ttl" ] || continue
    started="$REG_F_started"; case "$started" in ''|*[!0-9]*) started=0;; esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$started" "$REG_F_sid" "$REG_F_branch" "$REG_F_seen" "$REG_F_inwt"
  done
}

# Live sessions in the same repo but a DIFFERENT working tree (sibling
# worktrees: aware of, but no tangle risk). Emits: sid<TAB>branch<TAB>age_min
reg_other_tree() {
  local ttl=$(( TTL_MIN * 60 )) n f
  n=$(reg_now)
  for f in "$REG_DIR"/*.session; do
    [ -e "$f" ] || continue
    reg_load "$f"
    [ "$REG_F_toplevel" != "$REG_TOP" ] || continue
    case "$REG_F_seen" in ''|*[!0-9]*) continue;; esac
    [ $(( n - REG_F_seen )) -le "$ttl" ] || continue
    printf '%s\t%s\t%s\n' "$REG_F_sid" "$REG_F_branch" "$(( (n - REG_F_seen) / 60 ))"
  done
}

# Among same-tree live sessions (incl. self) am I the incumbent? Incumbent
# = earliest `started`, ties broken by lexically-smallest sid so every
# session computes the same winner. Returns 0 (true) when I am it.
reg_am_incumbent() {
  local best_started='' best_sid='' started sid rest
  while IFS=$'\t' read -r started sid rest; do
    [ -n "$sid" ] || continue
    if [ -z "$best_started" ]; then best_started="$started"; best_sid="$sid"; continue; fi
    if (( started < best_started )) || { (( started == best_started )) && [[ "$sid" < "$best_sid" ]]; }; then
      best_started="$started"; best_sid="$sid"
    fi
  done < <(reg_same_tree)
  [ -n "$best_sid" ] && [ "$best_sid" = "$REG_SID" ]
}

# Count non-empty lines (pure bash, no grep spawn).
reg_count() {
  local n=0 line
  while IFS= read -r line; do
    [ -n "$line" ] && n=$((n+1))
  done <<< "$1"
  printf '%s' "$n"
}

# Short peer list from same-tree (excludes self), max 4 shown.
reg_fmt_same() {
  local started sid branch seen inwt now age line out='' c=0
  now=$(reg_now)
  while IFS=$'\t' read -r started sid branch seen inwt; do
    [ -n "$sid" ] || continue
    [ "$sid" != "$REG_SID" ] || continue
    case "$seen" in ''|*[!0-9]*) seen=$now;; esac
    age=$(( (now - seen) / 60 ))
    line="${sid:0:8}(${branch:-?}, ${age}m"
    [ "${inwt:-no}" = yes ] && line="$line, wt"
    line="$line)"
    if [ -z "$out" ]; then out="$line"; else out="$out, $line"; fi
    c=$((c+1)); [ $c -ge 4 ] && { out="$out, ..."; break; }
  done < <(reg_same_tree)
  printf '%s' "$out"
}

# Short peer list from sibling worktrees, max 4 shown.
reg_fmt_other() {
  local sid branch age line out='' c=0
  while IFS=$'\t' read -r sid branch age; do
    [ -n "$sid" ] || continue
    line="${sid:0:8}(${branch:-?}, ${age}m)"
    if [ -z "$out" ]; then out="$line"; else out="$out, $line"; fi
    c=$((c+1)); [ $c -ge 4 ] && { out="$out, ..."; break; }
  done < <(reg_other_tree)
  printf '%s' "$out"
}

# Write/refresh my own entry. $1 = peer count to persist (for change
# detection on the next touch). started is preserved across writes.
reg_write() {
  local f="$REG_DIR/$REG_SID.session" tmp="$REG_DIR/$REG_SID.session.tmp.$$"
  {
    printf 'sid=%s\n'      "$REG_SID"
    printf 'ppid=%s\n'     "${PPID:-}"
    printf 'toplevel=%s\n' "$REG_TOP"
    printf 'common=%s\n'   "$REG_COMMON"
    printf 'inwt=%s\n'     "$REG_INWT"
    printf 'branch=%s\n'   "$REG_BRANCH"
    printf 'head=%s\n'     "$REG_HEAD"
    printf 'started=%s\n'  "$REG_STARTED"
    printf 'seen=%s\n'     "$(reg_now)"
    printf 'peers=%s\n'    "${1:-0}"
    printf 'host=%s\n'     "${HOSTNAME:-}"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null
}

reg_load_started() {
  local s; s=$(reg_getval started "$REG_DIR/$REG_SID.session")
  case "$s" in ''|*[!0-9]*) reg_now;; *) printf '%s' "$s";; esac
}

reg_emit_ctx() {
  # $1 event name, $2 already-escaped single-line text
  printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "%s",\n    "additionalContext": "%s"\n  }\n}\n' "$1" "$2"
}

# Human-readable table of every live session in this repo (read-only).
reg_list_table() {
  local ttl=$(( TTL_MIN * 60 )) n f age role any=no
  n=$(reg_now)
  printf 'Live agent sessions (TTL %dm)\nregistry: %s\n' "$TTL_MIN" "$REG_DIR"
  printf '  %-10s %-12s %-9s %5s  %s\n' sid branch where age toplevel
  for f in "$REG_DIR"/*.session; do
    [ -e "$f" ] || continue
    reg_load "$f"
    case "$REG_F_seen" in ''|*[!0-9]*) continue;; esac
    [ $(( n - REG_F_seen )) -le "$ttl" ] || continue
    any=yes
    age=$(( (n - REG_F_seen) / 60 )); role=checkout; [ "$REG_F_inwt" = yes ] && role=worktree
    printf '  %-10s %-12s %-9s %4dm  %s\n' "${REG_F_sid:0:10}" "${REG_F_branch:-?}" "$role" "$age" "$REG_F_toplevel"
  done
  [ "$any" = yes ] || printf '  (none)\n'
}

# Warn if local HEAD and origin/<mainline> have diverged into DISJOINT
# lineages (no common ancestor): a checkout stranded on a rewritten or
# orphan history that cannot push, where a force-push would obliterate
# origin. Read-only, NO fetch (uses the last-fetched ref), fail-open.
reg_lineage_warning() {
  local base="$1" mb main
  main=$(reg_mainline "$base")
  git -C "$base" rev-parse --verify -q HEAD >/dev/null 2>&1 || return 0
  git -C "$base" rev-parse --verify -q "origin/$main" >/dev/null 2>&1 || return 0
  mb=$(git -C "$base" merge-base HEAD "origin/$main" 2>/dev/null)
  if [ -z "$mb" ]; then
    printf '%s' "[LINEAGE ALERT] This checkout's HEAD has NO common ancestor with origin/$main: disjoint histories that cannot fast-forward. Do NOT push or force-push from here (a force-push obliterates origin's history). Reconcile first: get a clean checkout of origin/$main and re-apply local work there."
  fi
}

# ---------------------------------------------------------------------------
# CLI dispatch (executed directly only)
# ---------------------------------------------------------------------------

reg_main() {
  local mode="${1:-register}"
  local input flat raw_sid raw_cwd base
  input=$(cat)
  flat="${input//$'\n'/}"
  raw_sid=$(reg_extract session_id "$flat")
  raw_cwd=$(reg_norm_path "$(reg_extract cwd "$flat")")
  # Sanitize sid to [A-Za-z0-9_.-] in pure bash.
  local sid_in="${raw_sid:-unknown}" sid_out='' ch i
  for (( i=0; i<${#sid_in}; i++ )); do
    ch="${sid_in:$i:1}"
    case "$ch" in [A-Za-z0-9_.-]) sid_out+="$ch";; *) sid_out+='_';; esac
  done
  REG_SID="$sid_out"
  base="${raw_cwd:-${SENIOR_MODE_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-${CURSOR_PROJECT_DIR:-${GEMINI_PROJECT_DIR:-.}}}}}"

  if ! reg_resolve "$base"; then
    case "$mode" in register|unregister) exit 0;; esac
    printf '{}\n'; exit 0
  fi

  if [ "$mode" = "unregister" ]; then
    # SessionEnd: drop our own entry so peers stop seeing a ghost before
    # the TTL would have expired it. Output is ignored on SessionEnd.
    rm -f "$REG_DIR/$REG_SID.session" "$REG_DIR/$REG_SID.session.tmp."* 2>/dev/null || true
    exit 0
  fi

  reg_prune

  if [ "$mode" = "list" ]; then reg_list_table; exit 0; fi

  local f="$REG_DIR/$REG_SID.session" prev_peers
  prev_peers=$(reg_getval peers "$f"); case "$prev_peers" in ''|*[!0-9]*) prev_peers=-1;; esac
  REG_STARTED=$(reg_load_started)
  reg_write "$prev_peers"                       # ensure self present for counts

  local same n_same peers_same other n_other
  same=$(reg_same_tree);  n_same=$(reg_count "$same")
  peers_same=$(( n_same > 0 ? n_same - 1 : 0 ))
  other=$(reg_other_tree); n_other=$(reg_count "$other")
  reg_write "$peers_same"                       # persist current peer count

  local incumbent=no; reg_am_incumbent && incumbent=yes

  if [ "$mode" = "touch" ]; then
    # Heartbeat path: stay silent unless a NEW same-tree session appeared.
    if [ "$peers_same" -gt "$prev_peers" ] && [ "$peers_same" -gt 0 ]; then
      local list; list=$(reg_fmt_same)
      local note="[PARALLEL SESSIONS] A new agent session is now active in THIS checkout (${peers_same} other live here: ${list}). Two sessions committing in one checkout is what tangles the working tree."
      if [ "$REG_INWT" = no ] && [ "$incumbent" = no ]; then
        note="$note You are NOT the incumbent: before any commit, run /worktree to isolate. The tangle guard will block commit/push from this shared checkout until you do."
      fi
      reg_emit_ctx UserPromptSubmit "$(reg_json_escape "$note")"
      exit 0
    fi
    printf '{}\n'; exit 0
  fi

  # mode = register (SessionStart): build the situational banner.
  local ctx=''
  if [ "$REG_INWT" = yes ]; then
    local list; list=$(reg_fmt_other)
    ctx="[PARALLEL SESSIONS] You are in an ISOLATED WORKTREE (${REG_TOP}, branch ${REG_BRANCH}). No tangle risk with the main checkout."
    [ "$n_other" -gt 0 ] && ctx="$ctx Other live sessions: ${list}."
    ctx="$ctx To ship from here: git fetch origin, then git rebase origin/${REG_MAIN}, run checks, then push HEAD to ${REG_MAIN}. Run \`/worktree done\` to remove this worktree when finished."
  elif [ "$peers_same" -gt 0 ] && [ "$incumbent" = no ]; then
    local list; list=$(reg_fmt_same)
    ctx="[PARALLEL SESSIONS] CONCURRENT SESSION IN THIS CHECKOUT. You are 1 of $(( peers_same + 1 )) live sessions in ${REG_TOP} and you are NOT the incumbent. Two sessions committing in one checkout is exactly what tangles the working tree. Before ANY change that will be committed here, isolate this session: run \`/worktree\` to move onto your own branch + worktree off origin/${REG_MAIN} (git-isolation only; run dev/tests from the main checkout unless you install deps there). The tangle guard will BLOCK commit/push from this checkout for non-incumbent sessions. Live here: ${list}."
  elif [ "$peers_same" -gt 0 ] && [ "$incumbent" = yes ]; then
    local list; list=$(reg_fmt_same)
    ctx="[PARALLEL SESSIONS] You are the INCUMBENT (earliest) session in ${REG_TOP}; ${peers_same} later session(s) are also live in this same checkout and are expected to move into their own worktrees (the guard holds their commits/pushes until they do). You may keep working here normally. Alongside you: ${list}."
  elif [ "$n_other" -gt 0 ]; then
    local list; list=$(reg_fmt_other)
    ctx="[PARALLEL SESSIONS] ${n_other} other agent session(s) live in sibling worktrees: ${list}. You are the only session in this checkout (branch ${REG_BRANCH}). No tangle risk; coordinate the final push to ${REG_MAIN} (git fetch + rebase onto origin/${REG_MAIN} before pushing)."
  fi

  # Lineage health: a disjoint HEAD vs origin must warn even for a solo
  # session (it is the more dangerous case), so prepend before the exit.
  local lineage; lineage=$(reg_lineage_warning "$base")
  [ -n "$lineage" ] && ctx="${lineage}${ctx:+ }${ctx}"

  if [ -z "$ctx" ]; then
    exit 0    # solo: nothing to be aware of, stay silent
  fi
  reg_emit_ctx SessionStart "$(reg_json_escape "$ctx")"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  reg_main "$@"
fi
