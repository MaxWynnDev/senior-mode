#!/usr/bin/env bash
# Test harness for the kit's hooks. Feeds each hook a realistic stdin
# payload (a PreToolUse command, a PostToolUse edit, a SessionStart
# registration, a UserPromptSubmit prompt, or a Stop event) against
# scratch git repos and reports [ok]/[FAIL] by inspecting the JSON output.
# Outputs plain text (no `permissionDecision` keys at line start) so the
# Claude Code Bash harness does not intercept it.
#
# Covers:
#   - pre-push-checklist.sh trailer validation (deny/allow grades), and
#     that it validates the repo the push runs FROM (worktree fix)
#   - command self-filtering: non-push Bash calls pass through silently,
#     `git -C <dir> push` is caught, `git commit -m "...push..."` is not
#   - pre-commit-audit.sh: ignores non-commit commands; denies a bare
#     TODO in any comment syntax; allows TODO(owner, date)
#   - session-registry.sh + session-tree-guard.sh: second session in a
#     shared checkout is nudged to /worktree and blocked from committing;
#     the incumbent passes (with a warning); solo sessions stay silent;
#     `unregister` removes the entry
#   - exit-code-mask-guard.sh: piped CI watchers are denied, plain ones
#     and unrelated pipes pass
#   - ultracode-advisor.sh: a `.claude/` edit does not trip the auth
#     signal; a payments path does; keyword boundaries ("session",
#     "author", "className", "git checkout" stay quiet); a hit names its
#     reviewer; a task notification is ignored
#   - senior-check-after.sh undone-work check: a final answer that hands
#     back work is blocked, twice at most per turn and on push turns too;
#     quoted and code-span phrases are not hits; a turn with no shell call
#     and no edit skips the self-audit; the push flag does not outlive its
#     turn
#   - senior-check-before.sh: a prompt resets the turn state, a task
#     notification does not
#   - the starter's two senior-check hooks are byte-identical to core's
#   - post-edit-format.sh: silent no-op without a formatter, honors
#     CLAUDE_FORMAT_CMD, ignores non-edit tools, detects a local biome,
#     and speaks each adapter's edit-tool vocabulary (Factory Create,
#     Augment path key, the Codex/Devin apply_patch envelope)
#   - senior-check-after.sh Stop-hook backstop: blocks once per turn, and
#     stop_hook_active forces allow so it can never run to the block cap
#   - stacks/detect.sh verdicts and the --list picker
#   - the Cursor, Gemini, Devin, Copilot and Augment shims (payload
#     translation; Devin: nested deny -> top-level decision block,
#     Copilot: nested deny -> top-level permissionDecision, Augment:
#     conversation_id -> session_id and the nested Stop shape)
#   - the family generators: factory and devin configs carry their agents'
#     tool matchers, not Claude's; augment gets bare-path wrappers and no
#     UserPromptSubmit
#   - the copilot generator (command key, shim routing, no dead hooks)
#   - the OpenCode plugin under Bun: deny path, fail-open on a missing
#     guard, BEFORE context (skipped where bun is absent)
#   - install.sh dry run + real run into a scratch repo (kit source tree only)
#
# Run directly:  bash core/hooks/test-checklist.sh   (or .senior-mode/hooks/test-checklist.sh in an installed repo)
# Exit code: 0 when every case prints [ok], 1 otherwise.

HERE=$(cd "$(dirname "$0")" && pwd)
# Scratch repos are throwaway; keep Windows git from printing CRLF
# warnings between the [ok] lines.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false
PUSH_HOOK="$HERE/pre-push-checklist.sh"
COMMIT_HOOK="$HERE/pre-commit-audit.sh"
SCRATCH=$(mktemp -d)
# The hooks keep per-session state (stop sentinels, turn markers) in the
# temp dir. Give this run its own. A marker left behind by an earlier run
# changes what the next one sees: a leftover tools marker made a first
# stop look like a quiet turn.
export TMPDIR="$SCRATCH/tmp"
mkdir -p "$TMPDIR"
SESSION="test-checklist-session"
FAILS=0
trap 'rm -rf "$SCRATCH"; rm -f "${TMPDIR:-/tmp}/claude-push-done-$SESSION"' EXIT

ok()   { echo "[ok] $1"; }
fail() { echo "[FAIL] $1"; FAILS=$((FAILS+1)); }

payload() {
  # $1 = shell command to embed. Escape backslashes and double quotes the
  # way JSON.stringify would, so the hook sees a realistic payload.
  local esc=$1
  esc=${esc//\\/\\\\}
  esc=${esc//\"/\\\"}
  esc=${esc//$'\r'/\\r}
  esc=${esc//$'\n'/\\n}
  printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s","description":"test"}}' "$SESSION" "$esc"
}

# Fork-free classification (bash string matching, no piped grep). Git Bash
# on Windows can SIGABRT `grep` under the rapid git forking this harness
# does, so every check below avoids subshelling out to grep.
classify() {
  case "$1" in
    *'"permissionDecision": "deny"'*) echo deny ;;
    *'"additionalContext"'*)          echo allow ;;
    '{}'|$'{}\n')                      echo silent ;;
    *) [ "$(printf '%s' "$1" | tr -d '[:space:]')" = '{}' ] && echo silent || echo unknown ;;
  esac
}

run_case() {
  local hook="$1" name="$2" commit_msg="$3" cmd="$4" want="$5"
  rm -rf "$SCRATCH"/repo
  mkdir "$SCRATCH"/repo
  git -C "$SCRATCH"/repo init -q
  git -C "$SCRATCH"/repo -c user.email=t@t.t -c user.name=t commit --allow-empty -F - <<<"$commit_msg" -q
  local out got
  # Run FROM the scratch repo as well as setting CLAUDE_PROJECT_DIR: the
  # gates resolve HEAD from the command's cwd so a worktree push cannot
  # accidentally validate the main checkout's unrelated commit.
  out=$(cd "$SCRATCH/repo" && payload "$cmd" | CLAUDE_PROJECT_DIR="$SCRATCH/repo" bash "$hook")
  got=$(classify "$out")
  if [ "$got" = "$want" ]; then
    ok "$name -> $got"
  else
    fail "$name -> got=$got want=$want"
    echo "$out" | head -5
  fi
}

NO_TRAILER="test commit only"
VALID="test commit

Senior-Checklist: ambiguity=pass summary=pass concurrency=n/a regression=pass blast=green"

# --- pre-push: trailer validation on real pushes -----------------------
run_case "$PUSH_HOOK" "push, no trailer" "$NO_TRAILER" "git push origin main" "deny"
run_case "$PUSH_HOOK" "push, valid trailer" "$VALID" "git push origin main" "allow"
run_case "$PUSH_HOOK" "push, valid w/ miss" "test commit

Senior-Checklist: ambiguity=miss summary=pass concurrency=n/a regression=pass blast=red" "git push" "allow"
run_case "$PUSH_HOOK" "push, missing one key" "test commit

Senior-Checklist: ambiguity=pass summary=pass concurrency=n/a regression=pass" "git push" "deny"
run_case "$PUSH_HOOK" "push, invalid grade" "test commit

Senior-Checklist: ambiguity=lol summary=pass concurrency=n/a regression=pass blast=green" "git push" "deny"
run_case "$PUSH_HOOK" "push, blast=pass (uniform grade)" "test commit

Senior-Checklist: ambiguity=pass summary=pass concurrency=n/a regression=pass blast=pass" "git push" "allow"

# --- pre-push: command self-filtering ----------------------------------
run_case "$PUSH_HOOK" "non-git command passes through" "$NO_TRAILER" "ls -la && wc -l file.txt" "silent"
run_case "$PUSH_HOOK" "git commit is not a push" "$NO_TRAILER" "git commit -m \"do not push yet\"" "silent"
run_case "$PUSH_HOOK" "git -C dir push is caught" "$NO_TRAILER" "git -C $SCRATCH/repo push origin main" "deny"
run_case "$PUSH_HOOK" "chained cd && git push is caught" "$NO_TRAILER" "cd somewhere && git push" "deny"
run_case "$PUSH_HOOK" "git push inside quoted prose ignored" "$NO_TRAILER" "echo \"remember to git push later\"" "silent"

# --- pre-push: validates the repo the push runs FROM, not CLAUDE_PROJECT_DIR
# Main checkout has a VALID trailer; the "worktree" repo (cwd) has none.
# A gate that read CLAUDE_PROJECT_DIR would wrongly allow this push.
MAINREPO="$SCRATCH/mainrepo"; WTREPO="$SCRATCH/wt-like"
rm -rf "$MAINREPO" "$WTREPO"; mkdir -p "$MAINREPO" "$WTREPO"
git -C "$MAINREPO" init -q; git -C "$MAINREPO" -c user.email=t@t.t -c user.name=t commit --allow-empty -F - <<<"$VALID" -q
git -C "$WTREPO" init -q;   git -C "$WTREPO"   -c user.email=t@t.t -c user.name=t commit --allow-empty -m "no trailer here" -q
out=$(cd "$WTREPO" && payload "git push origin HEAD:main" | CLAUDE_PROJECT_DIR="$MAINREPO" bash "$PUSH_HOOK")
if [ "$(classify "$out")" = deny ]; then ok "push gate reads the cwd repo, not CLAUDE_PROJECT_DIR"; else fail "push gate validated the wrong repo (got $(classify "$out"))"; fi

# --- pre-commit: command self-filtering ---------------------------------
run_case "$COMMIT_HOOK" "pre-commit ignores non-commit" "$NO_TRAILER" "git push origin main" "silent"
run_case "$COMMIT_HOOK" "pre-commit fires on commit (no staged)" "$NO_TRAILER" "git commit -m \"msg\"" "allow"

# --- pre-commit: TODO gate is language-agnostic --------------------------
commit_with_staged() { # $1 name  $2 relpath  $3 content  $4 want
  local r="$SCRATCH/commitrepo" out got
  rm -rf "$r"; mkdir -p "$r/$(dirname "$2")"
  git -C "$r" init -q
  git -C "$r" -c user.email=t@t.t -c user.name=t commit --allow-empty -m init -q
  printf '%s\n' "$3" > "$r/$2"
  git -C "$r" add "$2"
  out=$(cd "$r" && payload 'git commit -m "x"' | CLAUDE_PROJECT_DIR="$r" bash "$COMMIT_HOOK")
  got=$(classify "$out")
  if [ "$got" = "$4" ]; then ok "$1 -> $got"; else fail "$1 -> got=$got want=$4"; echo "$out" | head -3; fi
}
commit_with_staged "pre-commit: bare python TODO denied"      "src/a.py"  "x = 1  # TODO fix this later" "deny"
commit_with_staged "pre-commit: bare JS FIXME denied"         "src/a.ts"  "const x = 1; // FIXME" "deny"
commit_with_staged "pre-commit: TODO(owner, date) allowed"    "src/b.ts"  "const y = 2; // TODO(alex, 2026-09-01): tighten" "allow"
commit_with_staged "pre-commit: console.log in prod path denied" "src/c.ts" "console.log('debug');" "deny"
commit_with_staged "pre-commit: console.log in scripts/ allowed" "scripts/c.ts" "console.log('report');" "allow"

# --- pre-commit: a commit that stages for itself is audited too -------------
# `git add ... && git commit` and `git commit -a` are how agents usually
# commit. The index is empty when the hook runs, so a gate that reads only
# the index lets all of them through. The hook replays the staging into a
# scratch index and must leave the real index and .git alone.
# The marker is assembled here so this file never contains one. The gate
# under test would deny a commit of its own harness otherwise.
MARK="TO""DO"
commit_chained() { # $1 name  $2 relpath  $3 content  $4 command  $5 want  [$6 yes = the file is tracked first]
  local r="$SCRATCH/chainrepo" out got f
  rm -rf "$r"; mkdir -p "$r/$(dirname "$2")"
  git -C "$r" init -q
  if [ "${6:-no}" = yes ]; then printf 'ok\n' > "$r/$2"; git -C "$r" add "$2"; fi
  git -C "$r" -c user.email=t@t.t -c user.name=t commit --allow-empty -m init -q
  printf '%s\n' "$3" > "$r/$2"
  out=$(cd "$r" && payload "$4" | CLAUDE_PROJECT_DIR="$r" bash "$COMMIT_HOOK")
  got=$(classify "$out")
  if [ -n "$(git -C "$r" diff --staged --name-only)" ]; then got="$got+staged-in-the-real-index"; fi
  for f in "$r"/.git/senior-audit-index.*; do [ -e "$f" ] && got="$got+scratch-index-left"; done
  if [ "$got" = "$5" ]; then ok "$1 -> $got"; else fail "$1 -> got=$got want=$5"; echo "$out" | head -3; fi
}
commit_chained "pre-commit: git add -A && git commit is audited"         "src/a.ts" "const x = 1; // $MARK fix" 'git add -A && git commit -m "x"' "deny"
commit_chained "pre-commit: git add <path> && git commit is audited"     "src/a.ts" "console.log('debug');"    'git add src/a.ts && git commit -m "x"' "deny"
commit_chained "pre-commit: git commit -am is audited"                   "src/a.ts" "const x = 1; // $MARK fix"    'git commit -am "x"' "deny" yes
commit_chained "pre-commit: a clean chained commit passes"               "src/a.ts" "export const x = 1;"      'git add -A && git commit -m "x"' "allow"
commit_chained "pre-commit: an add it cannot replay falls back to the index" "src/a.ts" "const x = 1; // $MARK fix" 'git add $FILES && git commit -m "x"' "allow"

# --- session-registry + session-tree-guard: concurrent-session safety ---
REG_HOOK="$HERE/session-registry.sh"
GUARD_HOOK="$HERE/session-tree-guard.sh"
WREPO="$SCRATCH/wtrepo"
rm -rf "$WREPO"; mkdir -p "$WREPO"
git -C "$WREPO" init -q
git -C "$WREPO" -c user.email=t@t.t -c user.name=t commit --allow-empty -m init -q

wt_payload() { # $1 sid  $2 cwd  $3 cmd(optional)
  local esc=${3:-}; esc=${esc//\\/\\\\}; esc=${esc//\"/\\\"}
  printf '{"session_id":"%s","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" "$2" "$esc"
}
wt_check() { # $1 name  $2 out  $3 needle  $4 want(yes|no)
  # tr, not ${v,,}: the ,, expansion is bash 4+ and macOS ships bash 3.2,
  # where it is a bad substitution that skips the case without failing it.
  local hay nee g
  hay=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  nee=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')
  if [[ "$hay" == *"$nee"* ]]; then g=yes; else g=no; fi
  if [ "$g" = "$4" ]; then ok "$1 -> $g"; else fail "$1 -> got=$g want=$4"; fi
}

wt_payload aaaa1111 "$WREPO" | bash "$REG_HOOK" register >/dev/null
wt_payload bbbb2222 "$WREPO" | bash "$REG_HOOK" register >/dev/null

wt_check "registry: 2nd session nudged to /worktree" \
  "$(wt_payload bbbb2222 "$WREPO" | bash "$REG_HOOK" register)" "/worktree" yes
wt_check "guard: non-incumbent commit blocked" \
  "$(wt_payload bbbb2222 "$WREPO" 'git commit -m x' | bash "$GUARD_HOOK")" '"permissionDecision": "deny"' yes
wt_check "guard: incumbent commit passes" \
  "$(wt_payload aaaa1111 "$WREPO" 'git commit -m x' | bash "$GUARD_HOOK")" "deny" no
wt_check "guard: incumbent warned about shared tree" \
  "$(wt_payload aaaa1111 "$WREPO" 'git commit -m x' | bash "$GUARD_HOOK")" "uncommitted" yes
wt_check "guard: read-only git passes" \
  "$(wt_payload bbbb2222 "$WREPO" 'git status' | bash "$GUARD_HOOK")" "deny" no
wt_check "guard: non-git command passes" \
  "$(wt_payload bbbb2222 "$WREPO" 'ls -la' | bash "$GUARD_HOOK")" "deny" no
wt_check "guard: explicit override honored" \
  "$(wt_payload bbbb2222 "$WREPO" 'CLAUDE_ALLOW_SHARED_GIT=1 git push' | bash "$GUARD_HOOK")" "overridden" yes

# unregister: after the incumbent leaves, the second session becomes solo
wt_payload aaaa1111 "$WREPO" | bash "$REG_HOOK" unregister >/dev/null
wt_check "registry: unregister removes the peer" \
  "$(wt_payload bbbb2222 "$WREPO" 'git commit -m x' | bash "$GUARD_HOOK")" "deny" no
REGDIR="$(git -C "$WREPO" rev-parse --path-format=absolute --git-common-dir)/claude-sessions"
if [ ! -e "$REGDIR/aaaa1111.session" ]; then ok "registry: unregistered session file deleted"; else fail "registry: session file survived unregister"; fi

SOLO="$SCRATCH/solorepo"; rm -rf "$SOLO"; mkdir -p "$SOLO"
git -C "$SOLO" init -q
git -C "$SOLO" -c user.email=t@t.t -c user.name=t commit --allow-empty -m i -q
wt_check "registry: solo session stays silent" \
  "$(wt_payload solo1 "$SOLO" | bash "$REG_HOOK" register)" "PARALLEL SESSIONS" no

# --- exit-code-mask-guard --------------------------------------------------
MASK_HOOK="$HERE/exit-code-mask-guard.sh"
run_case "$MASK_HOOK" "mask: piped gh run watch denied" "$NO_TRAILER" "gh run watch 123 --exit-status | tail -20" "deny"
run_case "$MASK_HOOK" "mask: piped gh pr checks --watch denied" "$NO_TRAILER" "gh pr checks 42 --watch | head" "deny"
run_case "$MASK_HOOK" "mask: redirected watcher passes" "$NO_TRAILER" "gh run watch 123 --exit-status > w.log 2>&1; echo WATCH_EXIT=\$?" "silent"
run_case "$MASK_HOOK" "mask: unrelated pipe passes" "$NO_TRAILER" "git log --oneline | head -5" "silent"
# only the watcher's own segment counts: a pipe in a later command, or an
# || after the redirect, does not touch the watcher's exit code
run_case "$MASK_HOOK" "mask: a pipe in a later command passes" "$NO_TRAILER" "gh run watch 123 --exit-status > w.log 2>&1; gh run view 123 --json jobs --jq '.jobs[] | .name'" "silent"
run_case "$MASK_HOOK" "mask: || after a redirected watcher passes" "$NO_TRAILER" "gh run watch 123 --exit-status > w.log 2>&1 || echo red" "silent"
run_case "$MASK_HOOK" "mask: a pipe before the ; is still denied" "$NO_TRAILER" "gh run watch 123 --exit-status 2>&1 | tee w.log; echo done" "deny"

# --- ultracode-advisor: path signals ignore the .claude tree ---------------
ULTRA_HOOK="$HERE/ultracode-advisor.sh"
UREPO="$SCRATCH/ultrarepo"; rm -rf "$UREPO"; mkdir -p "$UREPO/.claude/hooks" "$UREPO/src/payments"
git -C "$UREPO" init -q
printf 'x\n' > "$UREPO/.claude/hooks/session-registry.sh"; printf 'y\n' > "$UREPO/src/payments/charge.ts"
git -C "$UREPO" add -A; git -C "$UREPO" -c user.email=t@t.t -c user.name=t commit -m init -q
u_payload() { printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"%s"}' "$SESSION" "$1"; }
printf 'xx\n' > "$UREPO/.claude/hooks/session-registry.sh"
wt_check "ultracode: .claude edit does not trip auth" \
  "$(u_payload 'tidy the hook comments' | CLAUDE_PROJECT_DIR="$UREPO" bash "$ULTRA_HOOK")" "ULTRACODE" no
printf 'yy\n' > "$UREPO/src/payments/charge.ts"
wt_check "ultracode: payments path trips money" \
  "$(u_payload 'tidy the comments' | CLAUDE_PROJECT_DIR="$UREPO" bash "$ULTRA_HOOK")" "money" yes
wt_check "ultracode: prompt keyword trips migration" \
  "$(u_payload 'write the migration for the new column' | CLAUDE_PROJECT_DIR="$SOLO" bash "$ULTRA_HOOK")" "migration" yes

# --- post-edit-format: safe no-op + explicit opt-in + autodetect -----------
FMT_HOOK="$HERE/post-edit-format.sh"
FREPO="$SCRATCH/fmtrepo"; rm -rf "$FREPO"; mkdir -p "$FREPO"
printf 'const  x=1\n' > "$FREPO/a.ts"
fmt_payload() { # $1 tool  $2 file_path
  printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"%s","tool_input":{"file_path":"%s"}}' "$SESSION" "$1" "$2"
}
wt_check "format: no formatter -> silent no-op" \
  "$(fmt_payload Write "$FREPO/a.ts" | CLAUDE_PROJECT_DIR="$FREPO" bash "$FMT_HOOK")" "error" no
if [ "$(cat "$FREPO/a.ts")" = "const  x=1" ]; then ok "format: file untouched without a formatter"; else fail "format: file changed with no formatter configured"; fi
cat > "$FREPO/fake-fmt.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$1" > "$(dirname "$1")/fmt-marker"
EOF
fmt_payload Write "$FREPO/a.ts" | CLAUDE_PROJECT_DIR="$FREPO" CLAUDE_FORMAT_CMD="bash $FREPO/fake-fmt.sh" bash "$FMT_HOOK" >/dev/null
if [ -f "$FREPO/fmt-marker" ]; then ok "format: CLAUDE_FORMAT_CMD invoked on the edited file"; else fail "format: CLAUDE_FORMAT_CMD was not invoked"; fi
rm -f "$FREPO/fmt-marker"
fmt_payload Bash "$FREPO/a.ts" | CLAUDE_PROJECT_DIR="$FREPO" CLAUDE_FORMAT_CMD="bash $FREPO/fake-fmt.sh" bash "$FMT_HOOK" >/dev/null
if [ ! -f "$FREPO/fmt-marker" ]; then ok "format: non-edit tool ignored"; else fail "format: fired on a non-edit tool"; fi
# biome autodetect: config + local bin -> the bin is called with the file
mkdir -p "$FREPO/node_modules/.bin"; printf '{}\n' > "$FREPO/biome.json"
cat > "$FREPO/node_modules/.bin/biome" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$*" > "$(dirname "$0")/../../biome-marker"
EOF
chmod +x "$FREPO/node_modules/.bin/biome"
fmt_payload Edit "$FREPO/a.ts" | CLAUDE_PROJECT_DIR="$FREPO" bash "$FMT_HOOK" >/dev/null
if [ -f "$FREPO/biome-marker" ] && [[ "$(cat "$FREPO/biome-marker")" == *"format --write"* ]]; then ok "format: local biome auto-detected"; else fail "format: biome not detected"; fi

# --- post-edit-format: adapter-native tool vocabulary -----------------------
# Factory reports Create/Edit/ApplyPatch, Devin write/edit/apply_patch,
# Augment save-file/str-replace-editor with the file under "path", Codex
# apply_patch with the whole envelope in tool_input.command. A gate that
# only knows Write|Edit is dead on all of them.
rm -f "$FREPO/fmt-marker"
fmt_payload Create "$FREPO/a.ts" | CLAUDE_PROJECT_DIR="$FREPO" CLAUDE_FORMAT_CMD="bash $FREPO/fake-fmt.sh" bash "$FMT_HOOK" >/dev/null
if [ -f "$FREPO/fmt-marker" ]; then ok "format: Factory Create fires the formatter"; else fail "format: Factory Create ignored"; fi
rm -f "$FREPO/fmt-marker"
printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"str-replace-editor","tool_input":{"path":"%s"}}' "$SESSION" "$FREPO/a.ts" \
  | CLAUDE_PROJECT_DIR="$FREPO" CLAUDE_FORMAT_CMD="bash $FREPO/fake-fmt.sh" bash "$FMT_HOOK" >/dev/null
if [ -f "$FREPO/fmt-marker" ]; then ok "format: Augment str-replace-editor with a path key fires"; else fail "format: Augment path key ignored"; fi
rm -f "$FREPO/fmt-marker"
printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\\n*** Update File: a.ts\\n@@\\n+const x = 1\\n*** End Patch"}}' "$SESSION" \
  | (cd "$FREPO" && CLAUDE_PROJECT_DIR="$FREPO" CLAUDE_FORMAT_CMD="bash $FREPO/fake-fmt.sh" bash "$FMT_HOOK" >/dev/null)
if [ -f "$FREPO/fmt-marker" ] && [ "$(cat "$FREPO/fmt-marker")" = "a.ts" ]; then ok "format: apply_patch envelope yields the edited file"; else fail "format: apply_patch envelope not parsed"; fi
rm -f "$FREPO/fmt-marker"
fmt_payload Execute "$FREPO/a.ts" | CLAUDE_PROJECT_DIR="$FREPO" CLAUDE_FORMAT_CMD="bash $FREPO/fake-fmt.sh" bash "$FMT_HOOK" >/dev/null
if [ ! -f "$FREPO/fmt-marker" ]; then ok "format: shell tools stay ignored"; else fail "format: fired on a shell tool"; fi

# --- senior-check-after: Stop-hook loop backstop -----------------------
STOP_HOOK="$HERE/senior-check-after.sh"
SS="stop-test-session"
STOP_SENT="${TMPDIR:-/tmp}/claude-senior-stop-$SS"
rm -f "$STOP_SENT" "${TMPDIR:-/tmp}/claude-push-done-$SS" 2>/dev/null
stop_payload() { printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":%s}' "$SS" "$1"; }
sc_check() { # $1 name  $2 out  $3 want(yes|no)
  local g; if [[ "$2" == *'"decision": "block"'* ]]; then g=yes; else g=no; fi
  if [ "$g" = "$3" ]; then ok "$1 -> block=$g"; else fail "$1 -> block=$g want=$3"; fi
}
sc_check "stop: first stop of a turn blocks once" "$(stop_payload false | bash "$STOP_HOOK")" yes
sc_check "stop: second stop of the turn allows" "$(stop_payload false | bash "$STOP_HOOK")" no
rm -f "$STOP_SENT" 2>/dev/null   # simulate a fresh / failed sentinel (worst case)
sc_check "stop: stop_hook_active forces allow (no runaway)" "$(stop_payload true | bash "$STOP_HOOK")" no
rm -f "$STOP_SENT" "${TMPDIR:-/tmp}/claude-push-done-$SS" 2>/dev/null

# --- senior-check-after: undone work, quiet turns, the push flag ------------
# The Stop payload carries the final answer as last_assistant_message. An
# answer that hands back undone work is blocked (twice at most per turn),
# push turns included. A turn with no shell call and no edit skips the
# self-audit, but only once a tool hook has proved it is wired.
BEFORE_HOOK="$HERE/senior-check-before.sh"
TD="${TMPDIR:-/tmp}"
US="undone-test-session"
turn_reset() { rm -f "$TD/claude-senior-stop-$1" "$TD/claude-senior-undone-$1" "$TD/claude-senior-worked-$1" "$TD/claude-senior-tools-$1" "$TD/claude-push-done-$1" 2>/dev/null; }
answer() { # $1 active(true|false)  $2 final answer  [$3 session]
  local m=$2; m=${m//\\/\\\\}; m=${m//\"/\\\"}; m=${m//$'\n'/\\n}
  printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":%s,"last_assistant_message":"%s"}' "${3:-$US}" "$1" "$m"
}
stop_kind() { # block type of a Stop hook's output
  case "$1" in
    *'UNDONE WORK'*'SENIOR CHECK | AFTER'*) echo undone+after ;;
    *'UNDONE WORK'*)                        echo undone ;;
    *'SENIOR CHECK | AFTER'*)               echo after ;;
    '')                                     echo allow ;;
    *)                                      echo unknown ;;
  esac
}
uw_check() { # $1 name  $2 want  $3 hook output
  local g; g=$(stop_kind "$3")
  if [ "$g" = "$2" ]; then ok "$1 -> $g"; else fail "$1 -> got=$g want=$2"; fi
}
UNDONE_LIST=$'It is live.\n\n**What I didn\'t do**\n- tried the new scopes with a real key'

turn_reset "$US"
uw_check "undone: a 'what I didn't do' list is blocked, self-audit folded in" undone+after "$(answer false "$UNDONE_LIST" | bash "$STOP_HOOK")"
turn_reset "$US"
uw_check "undone: 'I haven't tested' is blocked" undone+after "$(answer false "Shipped. I haven't tested it against a real key." | bash "$STOP_HOOK")"
turn_reset "$US"
uw_check "undone: an 'Open items' heading is blocked" undone+after "$(answer false $'Done.\n\n## Open items\n- wire the retry' | bash "$STOP_HOOK")"
turn_reset "$US"
uw_check "undone: finished work gets the self-audit only" after "$(answer false "Fixed the parser and added a regression test. 14 of 14 pass." | bash "$STOP_HOOK")"
turn_reset "$US"
uw_check "undone: a failed check reported as failed is not undone work" after "$(answer false "CI is red: the split test fails with expected 100, got 99." | bash "$STOP_HOOK")"
turn_reset "$US"
uw_check "undone: the phrase inside a code span is not a hit" after "$(answer false 'The old hook asked for a `what I did not do` list.' | bash "$STOP_HOOK")"
turn_reset "$US"
uw_check "undone: the phrase inside quotes is not a hit" after "$(answer false 'The rule said "I haven'"'"'t tested" was an acceptable ending.' | bash "$STOP_HOOK")"

# the cap: the self-audit, then two undone blocks, then allow
turn_reset "$US"
uw_check "undone cap: stop 1 is the self-audit" after "$(answer false "Fixed it." | bash "$STOP_HOOK")"
uw_check "undone cap: stop 2 (active) blocks the revised answer" undone "$(answer true "Fixed it. I have not tested the retry." | bash "$STOP_HOOK")"
uw_check "undone cap: stop 3 (active) blocks once more" undone "$(answer true "Fixed it. I have not tested the retry." | bash "$STOP_HOOK")"
uw_check "undone cap: stop 4 allows, 3 blocks is the most a turn gets" allow "$(answer true "Fixed it. I have not tested the retry." | bash "$STOP_HOOK")"
if [ ! -e "$TD/claude-senior-stop-$US" ] && [ ! -e "$TD/claude-senior-undone-$US" ]; then ok "undone cap: the allow cleared the turn state"; else fail "undone cap: turn state survived the allow"; fi

# no state from earlier in the session: nothing proves the count would stick
turn_reset "$US"
uw_check "undone: stop_hook_active with no session state allows (no runaway)" allow "$(answer true "I have not tested the retry." | bash "$STOP_HOOK")"

# push turns: the self-audit stands down, the undone check does not
turn_reset "$US"; touch "$TD/claude-push-done-$US"
uw_check "undone: a push turn is still checked" undone "$(answer false "Pushed. I have not looked at the dialog." | bash "$STOP_HOOK")"
uw_check "undone: the push turn's corrected answer passes" allow "$(answer true "Pushed, and the dialog renders." | bash "$STOP_HOOK")"

# the push flag must not outlive its turn. Before this fix, a push made
# after the self-audit block left the flag behind and the next turn's
# self-audit was skipped.
turn_reset "$US"
answer false "Fixed it." | bash "$STOP_HOOK" >/dev/null
touch "$TD/claude-push-done-$US"
answer true "Fixed and pushed." | bash "$STOP_HOOK" >/dev/null
printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"next task"}' "$US" | bash "$BEFORE_HOOK" >/dev/null
uw_check "push flag: a push after the self-audit does not skip the next turn's" after "$(answer false "Did the next task." | bash "$STOP_HOOK")"

# quiet turns
turn_reset "$US"; touch "$TD/claude-senior-tools-$US"
uw_check "quiet turn: no shell call, no edit -> no self-audit" allow "$(answer false "The parser lives in src/parse.ts." | bash "$STOP_HOOK")"
turn_reset "$US"; touch "$TD/claude-senior-tools-$US"
uw_check "quiet turn: SENIOR_MODE_AFTER_ALWAYS=1 keeps the self-audit" after "$(answer false "The parser lives in src/parse.ts." | SENIOR_MODE_AFTER_ALWAYS=1 bash "$STOP_HOOK")"
turn_reset "$US"; touch "$TD/claude-senior-tools-$US"
uw_check "quiet turn: undone work is still blocked" undone+after "$(answer false "I have not checked the logs." | bash "$STOP_HOOK")"

# the markers come from the real tool hooks, not from this harness
turn_reset "$US"
printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls -la"}}' "$US" | bash "$PUSH_HOOK" >/dev/null
if [ -e "$TD/claude-senior-tools-$US" ] && [ -e "$TD/claude-senior-worked-$US" ]; then ok "markers: a shell call marks the turn as worked"; else fail "markers: pre-push hook did not write the turn markers"; fi
uw_check "markers: a turn that ran a command gets the self-audit" after "$(answer false "Listed the files." | bash "$STOP_HOOK")"
turn_reset "$US"
printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"%s/nope.txt"}}' "$US" "$SCRATCH" | CLAUDE_PROJECT_DIR="$SCRATCH" bash "$HERE/post-edit-format.sh" >/dev/null
if [ -e "$TD/claude-senior-worked-$US" ]; then ok "markers: an edit marks the turn as worked"; else fail "markers: post-edit hook did not write the turn marker"; fi

# SessionEnd removes the session's state files, in a repo or not
touch "$TD/claude-senior-stop-$US" "$TD/claude-senior-undone-$US" "$TD/claude-senior-worked-$US" "$TD/claude-senior-tools-$US" "$TD/claude-push-done-$US"
printf '{"session_id":"%s","hook_event_name":"SessionEnd","cwd":"%s"}' "$US" "$SCRATCH" | bash "$REG_HOOK" unregister >/dev/null
left=""; for f in stop undone worked tools; do [ -e "$TD/claude-senior-$f-$US" ] && left="$left $f"; done; [ -e "$TD/claude-push-done-$US" ] && left="$left push"
if [ -z "$left" ]; then ok "markers: SessionEnd removes the session's state files"; else fail "markers: SessionEnd left:$left"; fi

# the before hook: a real prompt resets the turn, a task notification does not
touch "$TD/claude-senior-stop-$US" "$TD/claude-senior-undone-$US" "$TD/claude-senior-worked-$US" "$TD/claude-push-done-$US" "$TD/claude-senior-tools-$US"
out=$(printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"fix the parser"}' "$US" | bash "$BEFORE_HOOK")
if [[ "$out" == *"SENIOR CHECK | BEFORE"* ]] && [ ! -e "$TD/claude-senior-worked-$US" ] && [ ! -e "$TD/claude-push-done-$US" ] && [ ! -e "$TD/claude-senior-undone-$US" ] && [ -e "$TD/claude-senior-tools-$US" ]; then
  ok "before: a prompt gets the checklist and resets the turn state"
else
  fail "before: prompt did not reset the turn state (got: ${out:0:80})"
fi
touch "$TD/claude-senior-worked-$US"
out=$(printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"<task-notification>\\n<task-id>a1</task-id>\\n<status>completed</status>"}' "$US" | bash "$BEFORE_HOOK")
if [ "$(printf '%s' "$out" | tr -d '[:space:]')" = '{}' ] && [ -e "$TD/claude-senior-worked-$US" ]; then
  ok "before: a task notification is silent and keeps the turn state"
else
  fail "before: task notification handled as a prompt (got: ${out:0:80})"
fi
turn_reset "$US"

# both block shapes are valid JSON, and neither has a double quote in its
# reason (the Cursor and Gemini shims re-embed the reason)
if command -v node >/dev/null 2>&1; then
  turn_reset "$US"
  if answer false "I haven't tested it." | bash "$STOP_HOOK" | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{const j=JSON.parse(s);process.exit(j.decision==="block"&&!j.reason.includes("\"")?0:1)})' 2>/dev/null; then
    ok "undone: the block parses as JSON and its reason has no double quote"
  else
    fail "undone: block is not valid JSON or its reason has a double quote"
  fi
  turn_reset "$US"
else
  ok "undone: (node absent) JSON parse check skipped"
fi

# --- ultracode-advisor: boundaries, reviewer routing, notifications ----------
adv_hits() { # the matched categories for a prompt, or "none"
  local o; o=$(u_payload "$1" | CLAUDE_PROJECT_DIR="$SOLO" bash "$ULTRA_HOOK")
  case "$o" in *"matched: "*) o=${o#*matched: }; printf '%s' "${o%%)*}" ;; *) printf 'none' ;; esac
}
adv_check() { # $1 prompt  $2 want
  local g; g=$(adv_hits "$1")
  if [ "$g" = "$2" ]; then ok "advisor: '$1' -> $g"; else fail "advisor: '$1' -> got=$g want=$2"; fi
}
adv_check "what happened in my last session" none
adv_check "the author left the className wrong" none
adv_check "git checkout the branch and open tests for it" none
adv_check "use dependency injection for the clock" none
adv_check "add authentication to the admin route" auth
adv_check "the session cookie expires too early" auth
adv_check "mask the SSN in the export" pii
adv_check "refund the duplicate payment" money
adv_check "check for sql injection in the search endpoint" audit
adv_check "<task-notification>\\n<result>auth, payment, login</result>" none
out=$(u_payload "refund the duplicate payment" | CLAUDE_PROJECT_DIR="$SOLO" bash "$ULTRA_HOOK")
if [[ "$out" == *"money-path-reviewer"* ]]; then ok "advisor: a money hit names the money-path-reviewer"; else fail "advisor: no reviewer named (got: $out)"; fi
if [[ "$out" == *"prefer a multi-agent Workflow"* ]]; then fail "advisor: still tells the agent to start a workflow"; else ok "advisor: leaves the workflow to the user"; fi

# --- the starter ships the same two senior-check hooks as the core -----------
STARTER="$HERE/../../starter/hooks"
if [ -d "$STARTER" ]; then
  for h in senior-check-before.sh senior-check-after.sh; do
    if cmp -s "$HERE/$h" "$STARTER/$h"; then ok "starter: $h matches core"; else fail "starter: $h drifted from core/hooks/$h"; fi
  done
fi

# --- stack detector ---------------------------------------------------------
DET="$HERE/../../stacks/detect.sh"; [ -f "$DET" ] || DET="$HERE/../stacks/detect.sh"
if [ -f "$DET" ]; then
  DREPO="$SCRATCH/det"; mkdir -p "$DREPO/next/src/app" "$DREPO/empty" "$DREPO/py/app" "$DREPO/php"
  printf '{"dependencies":{"next":"15","drizzle-orm":"0.40"}}' > "$DREPO/next/package.json"; : > "$DREPO/next/src/app/layout.tsx"; : > "$DREPO/next/vercel.ts"
  printf '[project]\ndependencies=["fastapi","sqlalchemy","alembic"]\n' > "$DREPO/py/pyproject.toml"; : > "$DREPO/py/app/main.py"; : > "$DREPO/py/alembic.ini"
  printf '{"name":"x/y"}' > "$DREPO/php/composer.json"
  out=$(bash "$DET" "$DREPO/next");  if [[ "$out" == *"DETECTED: nextjs-vercel-postgres"* ]]; then ok "detect: next.js fixture -> nextjs-vercel-postgres"; else fail "detect: next.js fixture"; echo "$out" | tail -3; fi
  out=$(bash "$DET" "$DREPO/py");    if [[ "$out" == *"DETECTED: python-fastapi-postgres"* ]]; then ok "detect: fastapi fixture -> python-fastapi-postgres"; else fail "detect: fastapi fixture"; echo "$out" | tail -3; fi
  out=$(bash "$DET" "$DREPO/empty"); if [[ "$out" == *"GREENFIELD"* ]]; then ok "detect: empty dir -> GREENFIELD"; else fail "detect: empty dir"; fi
  out=$(bash "$DET" "$DREPO/php");   if [[ "$out" == *"UNKNOWN"* ]]; then ok "detect: unmatched manifest -> UNKNOWN"; else fail "detect: unmatched manifest"; echo "$out" | tail -2; fi
  out=$(bash "$DET" --list);         if [[ "$out" == *"nextjs-vercel-postgres"* ]] && [[ "$out" == *"for:"* ]]; then ok "detect: --list prints the picker cards"; else fail "detect: --list"; fi
fi

# --- adapter shims (Cursor, Gemini) -----------------------------------------
CSHIM="$HERE/../../adapters/shims/cursor-shim.sh"; [ -f "$CSHIM" ] || CSHIM="$HERE/../adapters/cursor-shim.sh"
GSHIM="$HERE/../../adapters/shims/gemini-shim.sh"; [ -f "$GSHIM" ] || GSHIM="$HERE/../adapters/gemini-shim.sh"
if [ -f "$CSHIM" ] && [ -f "$GSHIM" ]; then
  SREPO="$SCRATCH/shim"; rm -rf "$SREPO"; mkdir -p "$SREPO"; git -C "$SREPO" init -q
  git -C "$SREPO" -c user.email=t@t.t -c user.name=t commit --allow-empty -m "no trailer here" -q
  out=$(cd "$SREPO" && printf '{"conversation_id":"s1","command":"git push origin main","cwd":"%s"}' "$SREPO" | CLAUDE_PROJECT_DIR="$SREPO" bash "$CSHIM" shell "$PUSH_HOOK")
  if [[ "$out" == *'"permission":"deny"'* ]]; then ok "cursor shim: push without trailer -> permission deny"; else fail "cursor shim: push deny (got: $out)"; fi
  out=$(cd "$SREPO" && printf '{"conversation_id":"s1","command":"ls -la","cwd":"%s"}' "$SREPO" | CLAUDE_PROJECT_DIR="$SREPO" bash "$CSHIM" shell "$PUSH_HOOK")
  if [[ "$out" == *'"permission":"allow"'* ]]; then ok "cursor shim: plain command -> permission allow"; else fail "cursor shim: allow (got: $out)"; fi
  out=$(printf '{"session_id":"s1"}' | bash "$CSHIM" session "$HERE/senior-check-before.sh")
  if [[ "$out" == *'"additional_context"'* ]] && [[ "$out" == *"SENIOR CHECK"* ]]; then ok "cursor shim: sessionStart carries the BEFORE checklist"; else fail "cursor shim: session context"; fi
  out=$(printf '{"conversation_id":"cs1","status":"done","loop_count":0}' | bash "$CSHIM" stop "$HERE/senior-check-after.sh")
  if [[ "$out" == *'"followup_message"'* ]] && [[ "$out" == *"SENIOR CHECK"* ]]; then ok "cursor shim: first stop -> followup carries the AFTER checklist"; else fail "cursor shim: stop followup (got: $out)"; fi
  # Fresh conversation id: no sentinel exists, so only the loop_count ->
  # stop_hook_active mapping can produce the allow. Same-id would pass via
  # the sentinel even without the mapping.
  out=$(printf '{"conversation_id":"cs2","status":"done","loop_count":1}' | bash "$CSHIM" stop "$HERE/senior-check-after.sh")
  if [ "$(printf '%s' "$out" | tr -d '[:space:]')" = '{}' ]; then ok "cursor shim: loop_count maps to stop_hook_active, follow-up stop passes"; else fail "cursor shim: stop backstop (got: $out)"; fi
  rm -f "${TMPDIR:-/tmp}/claude-senior-stop-cs1" "${TMPDIR:-/tmp}/claude-senior-stop-cs2"
  out=$(cd "$SREPO" && printf '{"session_id":"g1","hook_event_name":"BeforeTool","tool_name":"run_shell_command","cwd":"%s","tool_input":{"command":"git push origin main"}}' "$SREPO" | CLAUDE_PROJECT_DIR="$SREPO" bash "$GSHIM" BeforeTool "$PUSH_HOOK")
  if [[ "$out" == *'"decision":"deny"'* ]]; then ok "gemini shim: BeforeTool push without trailer -> decision deny"; else fail "gemini shim: deny (got: $out)"; fi
  out=$(printf '{"session_id":"g1","hook_event_name":"BeforeTool","tool_name":"run_shell_command","tool_input":{"command":"ls"}}' | bash "$GSHIM" BeforeTool "$PUSH_HOOK")
  if [ "$out" = "{}" ]; then ok "gemini shim: plain command -> {}"; else fail "gemini shim: allow (got: $out)"; fi
  out=$(printf '{"session_id":"g1","hook_event_name":"BeforeAgent","prompt":"hi"}' | bash "$GSHIM" BeforeAgent "$HERE/senior-check-before.sh")
  if [[ "$out" == *'"hookEventName":"BeforeAgent"'* ]] && [[ "$out" == *"SENIOR CHECK"* ]]; then ok "gemini shim: BeforeAgent carries the BEFORE checklist"; else fail "gemini shim: BeforeAgent context"; fi
  out=$(printf '{"session_id":"ga1","hook_event_name":"AfterAgent","stop_hook_active":false}' | bash "$GSHIM" AfterAgent "$HERE/senior-check-after.sh")
  if [[ "$out" == *'"decision":"deny"'* ]] && [[ "$out" == *"SENIOR CHECK"* ]]; then ok "gemini shim: AfterAgent block -> deny re-prompts with the AFTER checklist"; else fail "gemini shim: AfterAgent deny (got: $out)"; fi
  out=$(printf '{"session_id":"ga1","hook_event_name":"AfterAgent","stop_hook_active":true}' | bash "$GSHIM" AfterAgent "$HERE/senior-check-after.sh")
  if [ "$(printf '%s' "$out" | tr -d '[:space:]')" = '{}' ]; then ok "gemini shim: stop_hook_active passes through, retry is not re-denied"; else fail "gemini shim: AfterAgent backstop (got: $out)"; fi
  rm -f "${TMPDIR:-/tmp}/claude-senior-stop-ga1"
  # Gemini names the final answer prompt_response; the shim hands it to the
  # Stop hook as last_assistant_message
  out=$(printf '{"session_id":"ga2","hook_event_name":"AfterAgent","stop_hook_active":false,"prompt":"ship it","prompt_response":"Shipped. I have not tested the retry."}' | bash "$GSHIM" AfterAgent "$HERE/senior-check-after.sh")
  if [[ "$out" == *'"decision":"deny"'* ]] && [[ "$out" == *"UNDONE WORK"* ]]; then ok "gemini shim: prompt_response reaches the undone-work check"; else fail "gemini shim: prompt_response not mapped (got: ${out:0:120})"; fi
  rm -f "${TMPDIR:-/tmp}/claude-senior-stop-ga2" "${TMPDIR:-/tmp}/claude-senior-undone-ga2"
fi

# --- devin shim: nested guard deny -> top-level decision block ---------------
DSHIM="$HERE/../../adapters/shims/devin-shim.sh"; [ -f "$DSHIM" ] || DSHIM="$HERE/../adapters/devin-shim.sh"
if [ -f "$DSHIM" ]; then
  DREPO="$SCRATCH/devinshim"; rm -rf "$DREPO"; mkdir -p "$DREPO"; git -C "$DREPO" init -q
  git -C "$DREPO" -c user.email=t@t.t -c user.name=t commit --allow-empty -m "no trailer here" -q
  out=$(cd "$DREPO" && printf '{"session_id":"d1","hook_event_name":"PreToolUse","tool_name":"exec","tool_input":{"command":"git push origin main"}}' | CLAUDE_PROJECT_DIR="$DREPO" bash "$DSHIM" guard "$PUSH_HOOK")
  if [[ "$out" == *'"decision":"block"'* ]] && [[ "$out" != *"permissionDecision"* ]]; then ok "devin shim: push without trailer -> top-level decision block"; else fail "devin shim: deny (got: $out)"; fi
  out=$(cd "$DREPO" && printf '{"session_id":"d1","hook_event_name":"PreToolUse","tool_name":"exec","tool_input":{"command":"ls -la"}}' | CLAUDE_PROJECT_DIR="$DREPO" bash "$DSHIM" guard "$PUSH_HOOK")
  if [ "$(printf '%s' "$out" | tr -d '[:space:]')" = '{}' ]; then ok "devin shim: plain command -> {}"; else fail "devin shim: allow (got: $out)"; fi
fi

# --- family generators: factory and devin speak their agents' tool names -----
FGEN="$HERE/../../adapters/family/generate.sh"
if [ -f "$FGEN" ]; then
  FDREPO="$SCRATCH/family"; rm -rf "$FDREPO"; mkdir -p "$FDREPO"; git -C "$FDREPO" init -q
  bash "$FGEN" factory "$FDREPO" >/dev/null 2>&1
  bash "$FGEN" devin "$FDREPO" >/dev/null 2>&1
  FJ=$(cat "$FDREPO/.factory/hooks.json" 2>/dev/null)
  DJ=$(cat "$FDREPO/.devin/hooks.v1.json" 2>/dev/null)
  case "$FJ" in *'"matcher": "Execute"'*) ok "factory: shell guards match Execute" ;; *) fail "factory: shell guards do not match Execute" ;; esac
  case "$FJ" in *'"matcher": "Create|Edit|ApplyPatch"'*) ok "factory: formatter matches Create|Edit|ApplyPatch" ;; *) fail "factory: formatter matcher wrong" ;; esac
  case "$FJ" in *'$FACTORY_PROJECT_DIR'*) ok "factory: hook paths resolve via FACTORY_PROJECT_DIR" ;; *) fail "factory: hook paths not absolute" ;; esac
  case "$DJ" in *'"matcher": "exec"'*) ok "devin: shell guards match exec" ;; *) fail "devin: shell guards do not match exec" ;; esac
  case "$DJ" in *'"matcher": "write|edit|apply_patch"'*) ok "devin: formatter matches write|edit|apply_patch" ;; *) fail "devin: formatter matcher wrong" ;; esac
  case "$DJ" in *devin-shim.sh*) ok "devin: guards route through the deny shim" ;; *) fail "devin: PreToolUse does not use the shim" ;; esac
  if command -v node >/dev/null 2>&1; then
    if (cd "$FDREPO" && node -e "require('./.factory/hooks.json'); require('./.devin/hooks.v1.json')" >/dev/null 2>&1); then
      ok "family: generated factory and devin JSON parses"
    else
      fail "family: generated JSON does not parse"
    fi
  else
    ok "family: (node absent) JSON parse check skipped"
  fi
fi

# --- copilot shim: nested guard deny -> top-level permissionDecision ---------
PSHIM="$HERE/../../adapters/shims/copilot-shim.sh"; [ -f "$PSHIM" ] || PSHIM="$HERE/../adapters/copilot-shim.sh"
if [ -f "$PSHIM" ]; then
  PREPO="$SCRATCH/copilotshim"; rm -rf "$PREPO"; mkdir -p "$PREPO"; git -C "$PREPO" init -q
  git -C "$PREPO" -c user.email=t@t.t -c user.name=t commit --allow-empty -m "no trailer here" -q
  out=$(cd "$PREPO" && payload "git push origin main" | CLAUDE_PROJECT_DIR="$PREPO" bash "$PSHIM" guard "$PUSH_HOOK")
  case "$out" in
    *'"permissionDecision":"deny"'*)
      case "$out" in
        *hookSpecificOutput*) fail "copilot shim: deny still nested (got: $out)" ;;
        *) ok "copilot shim: push without trailer -> top-level permissionDecision deny" ;;
      esac ;;
    *) fail "copilot shim: deny (got: $out)" ;;
  esac
  out=$(cd "$PREPO" && payload "ls -la" | CLAUDE_PROJECT_DIR="$PREPO" bash "$PSHIM" guard "$PUSH_HOOK")
  if [ "$(printf '%s' "$out" | tr -d '[:space:]')" = '{}' ]; then ok "copilot shim: plain command -> {}"; else fail "copilot shim: allow (got: $out)"; fi
fi

# --- copilot generator: command key, shim routing, no dead prompt hooks ------
CGEN="$HERE/../../adapters/copilot/generate.sh"
if [ -f "$CGEN" ]; then
  CPREPO="$SCRATCH/copilotgen"; rm -rf "$CPREPO"; mkdir -p "$CPREPO"; git -C "$CPREPO" init -q
  bash "$CGEN" "$CPREPO" >/dev/null 2>&1
  CJ=$(cat "$CPREPO/.github/hooks/senior-mode.json" 2>/dev/null)
  case "$CJ" in *'"command": "bash'*) ok "copilot: hooks use the cross-platform command key" ;; *) fail "copilot: command key missing" ;; esac
  case "$CJ" in *'"bash":'*) fail "copilot: bash-only key still present (dead on Windows)" ;; *) ok "copilot: no bash-only key" ;; esac
  case "$CJ" in *copilot-shim.sh*) ok "copilot: guards route through the deny shim" ;; *) fail "copilot: PreToolUse does not use the shim" ;; esac
  case "$CJ" in *senior-check-before.sh*) fail "copilot: userPromptSubmitted hook wired though its output is dropped" ;; *) ok "copilot: no hooks wired where Copilot drops the output" ;; esac
  if command -v node >/dev/null 2>&1; then
    if (cd "$CPREPO" && node -e "require('./.github/hooks/senior-mode.json')" >/dev/null 2>&1); then
      ok "copilot: generated JSON parses"
    else
      fail "copilot: generated JSON does not parse"
    fi
  else
    ok "copilot: (node absent) JSON parse check skipped"
  fi
fi

# --- augment shim: conversation_id mapping, nested Stop shape ----------------
ASHIM="$HERE/../../adapters/shims/augment-shim.sh"; [ -f "$ASHIM" ] || ASHIM="$HERE/../adapters/augment-shim.sh"
if [ -f "$ASHIM" ]; then
  AREPO="$SCRATCH/augshim"; rm -rf "$AREPO"; mkdir -p "$AREPO"; git -C "$AREPO" init -q
  git -C "$AREPO" -c user.email=t@t.t -c user.name=t commit --allow-empty -m "no trailer here" -q
  rm -f "${TMPDIR:-/tmp}/claude-senior-stop-augconv"
  out=$(printf '{"hook_event_name":"Stop","conversation_id":"augconv","agent_stop_cause":"end_turn"}' | bash "$ASHIM" stop "$HERE/senior-check-after.sh")
  if [[ "$out" == *'"hookSpecificOutput":{"hookEventName":"Stop","decision":"block"'* ]]; then ok "augment shim: first stop -> block nested in hookSpecificOutput"; else fail "augment shim: stop shape (got: $out)"; fi
  # second stop passes via the sentinel, which only works if the shim mapped
  # conversation_id to the session_id the sentinel is keyed by
  out=$(printf '{"hook_event_name":"Stop","conversation_id":"augconv","agent_stop_cause":"end_turn"}' | bash "$ASHIM" stop "$HERE/senior-check-after.sh")
  if [ "$(printf '%s' "$out" | tr -d '[:space:]')" = '{}' ]; then ok "augment shim: second stop -> {} (conversation_id keyed the sentinel)"; else fail "augment shim: stop backstop (got: $out)"; fi
  rm -f "${TMPDIR:-/tmp}/claude-senior-stop-augconv"
  out=$(cd "$AREPO" && printf '{"hook_event_name":"PreToolUse","conversation_id":"augconv","tool_name":"launch-process","tool_input":{"command":"git push origin main"}}' | CLAUDE_PROJECT_DIR="$AREPO" bash "$ASHIM" guard "$PUSH_HOOK")
  if [ "$(classify "$out")" = deny ]; then ok "augment shim: push without trailer -> nested deny passed through"; else fail "augment shim: deny (got: $out)"; fi
  out=$(printf '{"hook_event_name":"SessionStart","conversation_id":"augconv"}' | bash "$ASHIM" session-start "$HERE/senior-check-before.sh")
  if [[ "$out" == *'"hookEventName":"SessionStart"'* ]] && [[ "$out" == *"SENIOR CHECK"* ]]; then ok "augment shim: sessionStart carries the BEFORE checklist"; else fail "augment shim: session context"; fi
fi

# --- augment generator: bare-path wrappers, real matchers, no dead events ----
AGEN="$HERE/../../adapters/family/generate.sh"
if [ -f "$AGEN" ] && [ -f "$ASHIM" ]; then
  AGREPO="$SCRATCH/auggen"; rm -rf "$AGREPO"; mkdir -p "$AGREPO"; git -C "$AGREPO" init -q
  bash "$AGEN" augment "$AGREPO" >/dev/null 2>&1
  AJ=$(cat "$AGREPO/.augment/settings.json" 2>/dev/null)
  case "$AJ" in *'"command": ".augment/hooks/senior-guards.sh"'*) ok "augment: command is a bare wrapper path" ;; *) fail "augment: command is not a bare script path" ;; esac
  case "$AJ" in *'"matcher": "launch-process"'*) ok "augment: shell guards match launch-process" ;; *) fail "augment: guards matcher wrong" ;; esac
  case "$AJ" in *'"matcher": "save-file|str-replace-editor"'*) ok "augment: formatter matches save-file|str-replace-editor" ;; *) fail "augment: formatter matcher wrong" ;; esac
  case "$AJ" in *UserPromptSubmit*) fail "augment: UserPromptSubmit wired but the event does not exist" ;; *) ok "augment: no UserPromptSubmit event wired" ;; esac
  wfirst=""; [ -f "$AGREPO/.augment/hooks/senior-stop.sh" ] && IFS= read -r wfirst < "$AGREPO/.augment/hooks/senior-stop.sh"
  if [ "$wfirst" = '#!/usr/bin/env bash' ]; then ok "augment: wrappers generated with a shebang"; else fail "augment: wrapper missing or without shebang"; fi
  # end to end through the wrapper, the way Augment would run it
  mkdir -p "$AGREPO/.senior-mode/adapters" "$AGREPO/.senior-mode/hooks"
  cp "$ASHIM" "$AGREPO/.senior-mode/adapters/augment-shim.sh"
  cp "$HERE/senior-check-after.sh" "$AGREPO/.senior-mode/hooks/"
  rm -f "${TMPDIR:-/tmp}/claude-senior-stop-augconv2"
  out=$(printf '{"hook_event_name":"Stop","conversation_id":"augconv2"}' | AUGMENT_PROJECT_DIR="$AGREPO" bash "$AGREPO/.augment/hooks/senior-stop.sh")
  if [[ "$out" == *'"decision":"block"'* ]]; then ok "augment: stop wrapper end to end -> nested block"; else fail "augment: wrapper end to end (got: $out)"; fi
  rm -f "${TMPDIR:-/tmp}/claude-senior-stop-augconv2"
  if command -v node >/dev/null 2>&1; then
    if (cd "$AGREPO" && node -e "require('./.augment/settings.json')" >/dev/null 2>&1); then
      ok "augment: generated JSON parses"
    else
      fail "augment: generated JSON does not parse"
    fi
  else
    ok "augment: (node absent) JSON parse check skipped"
  fi
fi

# --- opencode plugin (generated TS; executes only where bun exists) ----------
OGEN="$HERE/../../adapters/opencode/generate.sh"
if [ -f "$OGEN" ]; then
  if command -v bun >/dev/null 2>&1; then
    OREPO="$SCRATCH/opencode"; rm -rf "$OREPO"; mkdir -p "$OREPO"; git -C "$OREPO" init -q
    git -C "$OREPO" -c user.email=t@t.t -c user.name=t commit --allow-empty -m "no trailer here" -q
    bash "$OGEN" "$OREPO" >/dev/null 2>&1
    mkdir -p "$OREPO/.senior-mode/hooks"
    cp "$HERE/pre-push-checklist.sh" "$HERE/senior-check-before.sh" "$OREPO/.senior-mode/hooks/"
    cat > "$SCRATCH/oc-driver.ts" <<'DRIVER'
// Drives the generated OpenCode plugin under Bun against the real hooks.
// The missing guard scripts (only pre-push is copied) double as the
// fail-open case: a hook that is not there must allow, not crash.
import { $ } from "bun";
const dir = process.env.SM_OC_REPO as string;
const { SeniorMode } = await import(dir + "/.opencode/plugins/senior-mode.ts");
const plugin = await (SeniorMode as any)({ $, directory: dir });
let deny = "";
try {
  await plugin["tool.execute.before"]({ tool: "bash", sessionID: "oc1", callID: "c1" }, { args: { command: "git push origin main" } });
} catch (e) { deny = String(e); }
console.log(deny.includes("Push blocked") ? "DENY-OK" : "DENY-MISS " + deny);
let allow = "ALLOW-OK";
try {
  await plugin["tool.execute.before"]({ tool: "bash", sessionID: "oc1", callID: "c2" }, { args: { command: "ls" } });
} catch (e) { allow = "ALLOW-MISS " + String(e); }
console.log(allow);
const out = { system: [] as string[] };
await plugin["experimental.chat.system.transform"]({ sessionID: "oc1", model: {} }, out);
console.log(out.system.join(" ").includes("SENIOR CHECK") ? "CTX-OK" : "CTX-MISS");
DRIVER
    out=$(cd "$OREPO" && SM_OC_REPO="$OREPO" bun "$SCRATCH/oc-driver.ts" 2>&1)
    case "$out" in *DENY-OK*) ok "opencode plugin: push without trailer -> deny reason thrown" ;; *) fail "opencode plugin: deny (got: $out)" ;; esac
    case "$out" in *ALLOW-OK*) ok "opencode plugin: plain command passes, missing guards fail open" ;; *) fail "opencode plugin: allow (got: $out)" ;; esac
    case "$out" in *CTX-OK*) ok "opencode plugin: system transform carries the BEFORE checklist" ;; *) fail "opencode plugin: context (got: $out)" ;; esac
  else
    ok "opencode plugin: (bun absent) execution cases skipped"
  fi
fi

# --- codex generator: SessionEnd stays inside Codex's documented 3s cap ------
CXGEN="$HERE/../../adapters/codex/generate.sh"
if [ -f "$CXGEN" ]; then
  CXREPO="$SCRATCH/codexgen"; rm -rf "$CXREPO"; mkdir -p "$CXREPO"; git -C "$CXREPO" init -q
  bash "$CXGEN" "$CXREPO" >/dev/null 2>&1
  se_line=""; seen=no
  while IFS= read -r l; do
    [ "$seen" = yes ] && { se_line="$l"; break; }
    case "$l" in *'"SessionEnd"'*) seen=yes ;; esac
  done < "$CXREPO/.codex/hooks.json"
  case "$se_line" in
    *'"timeout": 3 }'*) ok "codex: SessionEnd timeout is 3 (documented max)" ;;
    *) fail "codex: SessionEnd timeout over the documented 3s cap (line: $se_line)" ;;
  esac
fi

# --- every adapter: SessionEnd stays inside the canonical 3s budget ----------
# Codex is the only agent documenting a cap (3s), but the budget is canonical:
# unregister is one rm. Several adapters carry hand-rolled configs that bypass
# the shared table in _lib.sh, so a clamp there does not reach them. This case
# reads the generated files instead of trusting the generator.
SEGEN="$HERE/../../install.sh"
if [ -f "$SEGEN" ]; then
  SEREPO="$SCRATCH/sessionend"; rm -rf "$SEREPO"; mkdir -p "$SEREPO"; git -C "$SEREPO" init -q
  bash "$SEGEN" --agent all "$SEREPO" >/dev/null 2>&1
  se_bad=""
  # <file>:<budget>, in whatever unit that agent's config uses
  for spec in ".claude/settings.json:3" ".codex/hooks.json:3" \
              ".factory/hooks.json:3" ".devin/hooks.v1.json:3" \
              ".github/hooks/senior-mode.json:3" ".gemini/settings.json:3000" \
              ".augment/settings.json:3000"; do
    f=${spec%:*}; want=${spec##*:}
    [ -f "$SEREPO/$f" ] || continue
    got=$(awk '{ s = s $0 }
      END {
        i = index(s, "\"SessionEnd\""); if (i == 0) exit;
        s = substr(s, i);
        if (match(s, /"timeout(Sec)?"[ \t]*:[ \t]*[0-9]+/)) {
          t = substr(s, RSTART, RLENGTH); sub(/^.*:[ \t]*/, "", t); print t
        }
      }' "$SEREPO/$f")
    [ -n "$got" ] || { se_bad="$se_bad $f=<none>"; continue; }
    [ "$got" -le "$want" ] 2>/dev/null || se_bad="$se_bad $f=$got(max $want)"
  done
  if [ -z "$se_bad" ]; then ok "every adapter: SessionEnd within the canonical 3s budget"
  else fail "SessionEnd over budget:$se_bad"; fi
fi

# --- install.sh (kit source tree only) ---------------------------------------
INSTALLER="$HERE/../../install.sh"
if [ -f "$INSTALLER" ]; then
  TREPO="$SCRATCH/target"; rm -rf "$TREPO"; mkdir -p "$TREPO"; git -C "$TREPO" init -q
  printf '# existing\n' > "$TREPO/CLAUDE.md"
  out=$(bash "$INSTALLER" --dry-run --agent claude --stack nextjs-vercel-postgres "$TREPO" 2>&1)
  if [[ "$out" == *"write"* ]] && [[ "$out" == *"CLAUDE.md"* ]] && [[ "$out" == *".senior-mode"* ]]; then
    ok "install: dry run plans writes and flags the existing CLAUDE.md for merge"
  else
    fail "install: dry run output unexpected"; echo "$out" | head -20
  fi
  if [ ! -d "$TREPO/.claude" ] && [ ! -d "$TREPO/.senior-mode" ]; then ok "install: dry run wrote nothing"; else fail "install: dry run wrote files"; fi
  out=$(bash "$INSTALLER" --agent claude,cursor --stack nextjs-vercel-postgres "$TREPO" 2>&1)
  if [ -f "$TREPO/.claude/settings.json" ] && [ -f "$TREPO/.claude/rules/api-routes.md" ] && [ -f "$TREPO/.cursor/hooks.json" ] \
     && [ -f "$TREPO/.agents/skills/review/SKILL.md" ] && [ -f "$TREPO/.senior-mode/hooks/pre-push-checklist.sh" ] \
     && [ -f "$TREPO/AGENTS.md" ] && [ -f "$TREPO/CLAUDE.md.senior-mode" ] && [ "$(cat "$TREPO/CLAUDE.md")" = "# existing" ]; then
    ok "install: real run installs core + claude + cursor wiring and preserves the existing CLAUDE.md"
  else
    fail "install: real run did not produce the expected tree"; echo "$out" | tail -20
  fi
  out=$(cd "$TREPO" && payload "git push origin main" | CLAUDE_PROJECT_DIR="$TREPO" bash .senior-mode/hooks/pre-push-checklist.sh)
  if [ "$(classify "$out")" = deny ]; then ok "install: the installed pre-push hook denies from its new location"; else fail "install: installed hook did not deny"; fi
  # A kit hook from an older version, and an AGENTS.md the project filled in.
  # A plain re-run keeps both. --upgrade replaces the hook (old copy backed
  # up) and still keeps AGENTS.md.
  printf '# hook from an older kit\n' > "$TREPO/.senior-mode/hooks/senior-check-after.sh"
  printf '# my project\n' > "$TREPO/AGENTS.md"
  bash "$INSTALLER" --agent claude --stack nextjs-vercel-postgres "$TREPO" >/dev/null 2>&1
  if [ "$(cat "$TREPO/.senior-mode/hooks/senior-check-after.sh")" = "# hook from an older kit" ] && [ -f "$TREPO/.senior-mode/hooks/senior-check-after.sh.senior-mode" ]; then
    ok "install: a plain re-run keeps an older hook and writes the new one beside it"
  else
    fail "install: plain re-run touched an existing hook"
  fi
  bash "$INSTALLER" --upgrade --agent claude --stack nextjs-vercel-postgres "$TREPO" >/dev/null 2>&1
  bk=""; for d in "$TREPO"/.senior-mode/backup/*/; do [ -f "$d.senior-mode/hooks/senior-check-after.sh" ] && bk=$(cat "$d.senior-mode/hooks/senior-check-after.sh"); done
  if cmp -s "$HERE/senior-check-after.sh" "$TREPO/.senior-mode/hooks/senior-check-after.sh" \
     && [ "$bk" = "# hook from an older kit" ] \
     && [ "$(cat "$TREPO/AGENTS.md")" = "# my project" ] \
     && [ ! -e "$TREPO/.senior-mode/hooks/senior-check-after.sh.senior-mode" ]; then
    ok "install: --upgrade replaces the kit's hook, backs up the old copy, keeps AGENTS.md"
  else
    fail "install: --upgrade did not behave (backup: '$bk')"
  fi
  if command -v node >/dev/null 2>&1; then
    if (cd "$TREPO" && node -e "require('./.claude/settings.json'); require('./.cursor/hooks.json')" >/dev/null 2>&1); then
      ok "install: generated .claude/settings.json and .cursor/hooks.json parse as JSON"
    else
      fail "install: generated JSON does not parse"
    fi
  else
    ok "install: (node absent) JSON parse check skipped"
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL CASES [ok]"; exit 0; else echo "$FAILS CASE(S) FAILED"; exit 1; fi
