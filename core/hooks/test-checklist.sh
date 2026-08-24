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
#     signal; a payments path does
#   - post-edit-format.sh: silent no-op without a formatter, honors
#     CLAUDE_FORMAT_CMD, ignores non-edit tools, detects a local biome
#   - senior-check-after.sh Stop-hook backstop: blocks once per turn, and
#     stop_hook_active forces allow so it can never run to the block cap
#   - stacks/detect.sh verdicts and the --list picker
#   - the Cursor and Gemini shims (payload translation both ways)
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
  local hay=${2,,} nee=${3,,} g
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
  out=$(cd "$SREPO" && printf '{"session_id":"g1","hook_event_name":"BeforeTool","tool_name":"run_shell_command","cwd":"%s","tool_input":{"command":"git push origin main"}}' "$SREPO" | CLAUDE_PROJECT_DIR="$SREPO" bash "$GSHIM" BeforeTool "$PUSH_HOOK")
  if [[ "$out" == *'"decision":"deny"'* ]]; then ok "gemini shim: BeforeTool push without trailer -> decision deny"; else fail "gemini shim: deny (got: $out)"; fi
  out=$(printf '{"session_id":"g1","hook_event_name":"BeforeTool","tool_name":"run_shell_command","tool_input":{"command":"ls"}}' | bash "$GSHIM" BeforeTool "$PUSH_HOOK")
  if [ "$out" = "{}" ]; then ok "gemini shim: plain command -> {}"; else fail "gemini shim: allow (got: $out)"; fi
  out=$(printf '{"session_id":"g1","hook_event_name":"BeforeAgent","prompt":"hi"}' | bash "$GSHIM" BeforeAgent "$HERE/senior-check-before.sh")
  if [[ "$out" == *'"hookEventName":"BeforeAgent"'* ]] && [[ "$out" == *"SENIOR CHECK"* ]]; then ok "gemini shim: BeforeAgent carries the BEFORE checklist"; else fail "gemini shim: BeforeAgent context"; fi
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
