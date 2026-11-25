#!/usr/bin/env bash
# Cases for the boundary probe, the package install guard, the profile
# lookup, and the wiring every adapter generates for the new guard.
#
# Sourced by ../test-checklist.sh after 10-code-checks.sh and 20-gates.sh.

PX_PROBE="$HERE/boundary-probe.sh"
PX_INSTALL="$HERE/package-install-guard.sh"

# --- boundary probe -----------------------------------------------------------------
# The "tests" here are greps: one that only passes while the boundary is
# exactly as written, and one that passes no matter what.
B="$SCRATCH/px-probe"; newrepo "$B"
put "$B/src/page.js" 'export function page(items, size) {
  return items;
}'
git -C "$B" add -A; git -C "$B" -c user.email=t@t.t -c user.name=t commit -q -m base
put "$B/src/page.js" 'export function page(items, size) {
  const out = [];
  for (let i = 0; i < size; i++) out.push(items[i]);
  const last = items.length - 1;
  return out.concat(items[last]);
}'
cp "$B/src/page.js" "$SCRATCH/px-page-before.js"
probe() { (cd "$B" && bash "$PX_PROBE" "$@" 2>&1); }

out=$(probe --test "grep -q 'i < size' src/page.js && grep -q 'length - 1;' src/page.js"); rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"KILLED    src/page.js:3"* ]] && [[ "$out" == *"KILLED    src/page.js:4"* ]] && [[ "$out" == *"PROBE_EXIT=0"* ]]; then ok "probe: flips a pinned comparison and a pinned - 1, and both are killed"; else fail "probe: pinned boundaries (rc=$rc)"; printf '%s\n' "$out" | head -12; fi
out=$(probe --test "true"); rc=$?
if [ "$rc" -eq 1 ] && [[ "$out" == *"SURVIVED  src/page.js:3"* ]] && [[ "$out" == *"2 of 2 flips stayed green"* ]] && [[ "$out" == *"Every flip survived"* ]]; then ok "probe: a suite that cannot fail leaves every flip alive, exit 1"; else fail "probe: unpinned boundaries (rc=$rc)"; printf '%s\n' "$out" | head -12; fi
out=$(probe --test "grep -q 'i < size' src/page.js"); rc=$?
if [ "$rc" -eq 1 ] && [[ "$out" == *"KILLED    src/page.js:3"* ]] && [[ "$out" == *"SURVIVED  src/page.js:4"* ]] && [[ "$out" == *"1 of 2 flips stayed green"* ]]; then ok "probe: names the one boundary no test pins"; else fail "probe: mixed result (rc=$rc)"; printf '%s\n' "$out" | head -12; fi
out=$(probe --test "false"); rc=$?
if [ "$rc" -eq 2 ] && [[ "$out" == *"BASELINE RED"* ]]; then ok "probe: a red baseline stops it before any flip"; else fail "probe: red baseline (rc=$rc)"; printf '%s\n' "$out" | head -8; fi
out=$(probe); rc=$?
if [ "$rc" -eq 2 ] && [[ "$out" == *"no test command is known"* ]]; then ok "probe: no test command known exits 2 and says how to pass one"; else fail "probe: missing test command (rc=$rc): $out"; fi
if cmp -s "$B/src/page.js" "$SCRATCH/px-page-before.js"; then ok "probe: the probed file is byte-identical afterwards"; else fail "probe: the file was left changed"; fi
out=$(probe --max 1 --test "true")
if [[ "$out" == *"1 more boundaries were not probed"* ]]; then ok "probe: --max caps the flips and says how many were left"; else fail "probe: --max: $out"; fi
# a run that died half way: the next run puts the original back first
GDP=$(git -C "$B" rev-parse --absolute-git-dir)
mkdir -p "$GDP/senior-mode"
cp "$B/src/page.js" "$GDP/senior-mode/probe-original.dead"
printf 'a flip that a killed run left behind\n' > "$B/src/page.js"
printf '%s\n%s\n' "$GDP/senior-mode/probe-original.dead" "$B/src/page.js" > "$GDP/senior-mode/probe-restore"
out=$(probe --test "true")
if cmp -s "$B/src/page.js" "$SCRATCH/px-page-before.js" && [[ "$out" == *"Restoring the file"* ]]; then ok "probe: an interrupted run is restored before the next one starts"; else fail "probe: interrupted run not restored"; fi
git -C "$B" checkout -q -- src/page.js
out=$(probe --test "true"); rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"Nothing to probe"* ]]; then ok "probe: no changed boundary, nothing to probe, exit 0"; else fail "probe: clean tree (rc=$rc): $out"; fi
# test files and comments are not probed
put "$B/src/page.test.js" 'if (a < b) fail();'
put "$B/src/notes.js" '// when i < size we stop
const s = "a < b";'
out=$(probe --test "true"); rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"Nothing to probe"* ]]; then ok "probe: a test file, a comment and a string are left alone"; else fail "probe: probed a test, comment or string (rc=$rc): $out"; fi

# --- package install guard ------------------------------------------------------------------
# A stand-in curl on PATH answers for the registries, so no case needs a network.
PXBIN="$SCRATCH/px-bin"; mkdir -p "$PXBIN"
cat > "$PXBIN/curl" <<'EOF'
#!/usr/bin/env bash
# Test double: the last argument is the URL.
for a in "$@"; do url="$a"; done
echo "$url" >> "$(dirname "$0")/curl-calls"
case "$url" in
  *api.npmjs.org*zz-invented*) printf '{"error":"not found"}\n404' ;;
  *api.npmjs.org*quiet-lookalike*) printf '{"downloads":12,"package":"quiet-lookalike"}\n200' ;;
  *api.npmjs.org*registry-down*) printf 'gateway timeout\n504' ;;
  *api.npmjs.org*) printf '{"downloads":4200000,"package":"x"}\n200' ;;
  *pypi.org*zz-invented*) printf '404' ;;
  *pypi.org*) printf '200' ;;
esac
EOF
chmod +x "$PXBIN/curl"
I="$SCRATCH/px-install"; newrepo "$I"
put "$I/package.json" '{"dependencies":{"already-here":"1.0.0"}}'
PX_N=0
guard() { # <name> <command> <want> [<text the reason must carry>]
  local out got
  out=$(cd "$I" && payload "$2" | PATH="$PXBIN:$PATH" CLAUDE_PROJECT_DIR="$I" bash "$PX_INSTALL")
  got=$(classify "$out")
  if [ "$got" = "$3" ] && { [ -z "${4:-}" ] || [[ "$out" == *"$4"* ]]; }; then ok "$1 -> $got"; else fail "$1 -> got=$got want=$3 ${4:+(carrying: $4)}"; printf '%s\n' "$out" | head -3; fi
}
rm -f "$TMPDIR/claude-senior-pkg-$SESSION"
guard "install: a name the registry does not have is denied"      "npm install zz-invented-thing" deny "no package named zz-invented-thing on npm"
guard "install: the same command again goes through"              "npm install zz-invented-thing" silent
guard "install: a real name almost nobody downloads is denied once" "cd web && pnpm add -D quiet-lookalike@1.2.3" deny "had 12 downloads last week"
guard "install: a widely used package passes"                     "npm i --save-dev @types/node left-pad" silent
: > "$PXBIN/curl-calls"
guard "install: a package the repo already uses is not looked up" "npm install already-here" silent
guard "install: a bare install is not looked up"                  "npm install" silent
guard "install: a requirements file is not a package name"        "pip install -r requirements.txt -e ." silent
guard "install: the words inside a commit message are not a command" "git commit -m \"npm install zz-invented-other\"" silent
if [ ! -s "$PXBIN/curl-calls" ]; then ok "install: none of those four reached the registry"; else fail "install: an unneeded lookup happened: $(cat "$PXBIN/curl-calls")"; fi
guard "install: a made-up PyPI name is denied"                    "python -m pip install zz-invented-py==1.0" deny "no package named zz-invented-py on PyPI"
guard "install: uv add of a real name passes"                     "uv add requests" silent
guard "install: an answer it does not recognise allows"           "npm install registry-down" silent
out=$(cd "$I" && payload "npm install zz-invented-off" | PATH="$PXBIN:$PATH" SENIOR_MODE_INSTALL_LOOKUP=off bash "$PX_INSTALL")
if [ "$(classify "$out")" = silent ]; then ok "install: SENIOR_MODE_INSTALL_LOOKUP=off turns it off"; else fail "install: the off switch did not hold"; fi
rm -f "$TMPDIR/claude-senior-pkg-$SESSION"

# --- the installed profile feeds the hooks, and every adapter wires the new guard -----------------
PX_INSTALLER="$HERE/../../install.sh"
if [ -f "$PX_INSTALLER" ]; then
  W="$SCRATCH/px-wiring"; rm -rf "$W"; mkdir -p "$W"; git -C "$W" init -q
  bash "$PX_INSTALLER" --agent all --stack nextjs-vercel-postgres "$W" >/dev/null 2>&1
  for f in lib/check-js.mjs lib/js-lex.mjs lib/js-facts.mjs lib/js-bounds.mjs lib/js-resolve.mjs lib/check-ts-types.mjs lib/check-json.mjs lib/check-py.py lib/py_facts.py lib/profile.sh post-edit-check.sh check.sh boundary-probe.sh package-install-guard.sh; do
    [ -f "$W/.senior-mode/hooks/$f" ] || fail "wiring: install.sh did not copy hooks/$f"
  done
  ok "wiring: install.sh copies the check helpers and the new hooks"
  if [ "$(cat "$W/.senior-mode/stacks/ACTIVE" 2>/dev/null)" = nextjs-vercel-postgres ]; then ok "wiring: install.sh records the active stack profile"; else fail "wiring: stacks/ACTIVE missing or wrong"; fi
  got=$(. "$HERE/lib/profile.sh"; sm_cmd "$W" typecheck)
  if [ "$got" = "pnpm typecheck" ]; then ok "profile: the hooks read the typecheck command of the installed profile"; else fail "profile: typecheck command read as '$got'"; fi
  got=$(. "$HERE/lib/profile.sh"; SENIOR_MODE_TYPECHECK_CMD="my check" sm_cmd "$W" typecheck)
  if [ "$got" = "my check" ]; then ok "profile: the environment wins over the profile"; else fail "profile: env override read as '$got'"; fi
  missing=""
  for f in .claude/settings.json .codex/hooks.json .cursor/hooks.json .gemini/settings.json .github/hooks/senior-mode.json \
           .factory/hooks.json .devin/hooks.v1.json .augment/hooks/senior-guards.sh .opencode/plugins/senior-mode.ts; do
    case "$(cat "$W/$f" 2>/dev/null)" in *package-install-guard.sh*) ;; *) missing="$missing $f" ;; esac
  done
  if [ -z "$missing" ]; then ok "wiring: all nine adapters run the package install guard"; else fail "wiring: the install guard is not wired in:$missing"; fi
  if out=$(cd "$W" && payload "npm install zz-invented-wired" | PATH="$PXBIN:$PATH" CLAUDE_PROJECT_DIR="$W" bash .senior-mode/hooks/package-install-guard.sh) && [ "$(classify "$out")" = deny ]; then
    ok "wiring: the installed guard denies from its installed location"
  else
    fail "wiring: the installed guard did not deny"
  fi
  rm -f "$TMPDIR/claude-senior-pkg-$SESSION"
fi

# a repo with no profile: the manifest's own typecheck script, with the lockfile's package manager
M="$SCRATCH/px-manifest"; newrepo "$M"
put "$M/package.json" '{ "name": "m", "scripts": { "build": "x", "typecheck": "tsc --noEmit" } }'
put "$M/pnpm-lock.yaml" 'lockfileVersion: 9'
got=$(. "$HERE/lib/profile.sh"; sm_cmd "$M" typecheck)
if [ "$got" = "pnpm run typecheck" ]; then ok "profile: with no profile, a typecheck script in package.json is found"; else fail "profile: manifest detection read as '$got'"; fi
got=$(. "$HERE/lib/profile.sh"; sm_cmd "$M" test)
if [ -z "$got" ]; then ok "profile: a test command is never guessed"; else fail "profile: guessed a test command: '$got'"; fi
