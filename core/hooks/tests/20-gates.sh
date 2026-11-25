#!/usr/bin/env bash
# Cases for the gates around the checker: the commit denies, the shell
# guards, the receipt runner and the Stop hook's receipt line.
#
# Sourced by ../test-checklist.sh after 10-code-checks.sh, which defines
# put, newrepo and the SX_ variables.

GX_COMMIT="$HERE/pre-commit-audit.sh"
GX_MASK="$HERE/exit-code-mask-guard.sh"
GX_STOP="$HERE/senior-check-after.sh"

# --- pre-commit: a new suppression needs its reason --------------------------------
staged() { # <name> <relpath> <content> <want> [<commit command>]
  local r="$SCRATCH/gx-commit" out got
  newrepo "$r"
  put "$r/$2" "$3"
  git -C "$r" add -A
  out=$(cd "$r" && payload "${5:-git commit -m x}" | CLAUDE_PROJECT_DIR="$r" bash "$GX_COMMIT")
  got=$(classify "$out")
  if [ "$got" = "$4" ]; then ok "$1 -> $got"; else fail "$1 -> got=$got want=$4"; printf '%s\n' "$out" | head -4; fi
}
staged "suppress: @ts-ignore is denied"                       "src/a.ts" 'const a = 1;
// @ts-ignore
const b: string = a;' deny
staged "suppress: a bare @ts-expect-error is denied"          "src/a.ts" '// @ts-expect-error
export const b: string = 1;' deny
staged "suppress: @ts-expect-error with its reason passes"    "src/a.ts" '// @ts-expect-error the vendor type omits the id field
export const b: string = 1;' allow
staged "suppress: a cast to any with no comment is denied"    "src/a.ts" 'declare const raw: unknown;
export const row = raw as any;' deny
staged "suppress: a cast to any with a reason beside it passes" "src/a.ts" 'declare const raw: unknown;
export const row = raw as any; // the driver returns untyped rows' allow
staged "suppress: a cast to any under a comment line passes"  "src/a.ts" 'declare const raw: unknown;
// the driver returns untyped rows
export const row = raw as any;' allow
staged "suppress: a cast to any in a test file passes"        "src/a.test.ts" 'export const bad = "x" as any;' allow
staged "suppress: eslint-disable with no reason is denied"    "src/a.js" '// eslint-disable-next-line no-undef
export const v = thing;' deny
staged "suppress: eslint-disable with -- a reason passes"     "src/a.js" '// eslint-disable-next-line no-undef -- injected by the host page
export const v = thing;' allow
staged "suppress: a bare type: ignore is denied"              "app/a.py" 'x: int = "a"  # type: ignore' deny
staged "suppress: type: ignore with its code passes"          "app/a.py" 'x: int = "a"  # type: ignore[assignment]' allow
staged "suppress: a bare noqa is denied"                      "app/a.py" 'import os  # noqa' deny
staged "suppress: a bare nolint is denied"                    "pkg/a.go" 'package pkg

var x = 1 //nolint' deny

# --- pre-commit: a looser checker config needs a reason too ---------------------------
staged "loosen: a strict flag turned off is denied"           "tsconfig.json" '{
  "compilerOptions": {
    "strict": false
  }
}' deny
staged "loosen: the same flag with a reason beside it passes" "tsconfig.json" '{
  "compilerOptions": {
    "strict": false // the generated client is not strict-clean yet, tracked in the migration plan
  }
}' allow
staged "loosen: ignoreBuildErrors is denied"                  "next.config.js" 'module.exports = {
  typescript: { ignoreBuildErrors: true },
};' deny
staged "loosen: mypy ignore_errors is denied"                 "mypy.ini" '[mypy]
ignore_errors = True' deny
staged "loosen: a strict tsconfig passes"                     "tsconfig.json" '{ "compilerOptions": { "strict": true } }' allow
# a tsconfig whose exclude list grows
r="$SCRATCH/gx-exclude"; newrepo "$r"
put "$r/tsconfig.json" '{ "compilerOptions": { "strict": true }, "exclude": ["node_modules"] }'
git -C "$r" add -A; git -C "$r" -c user.email=t@t.t -c user.name=t commit -q -m base
put "$r/tsconfig.json" '{ "compilerOptions": { "strict": true }, "exclude": ["node_modules", "src/legacy"] }'
git -C "$r" add -A
out=$(cd "$r" && payload "git commit -m x" | CLAUDE_PROJECT_DIR="$r" bash "$GX_COMMIT")
if [ "$(classify "$out")" = deny ] && [[ "$out" == *"exclude grew from 1 to 2"* ]]; then ok "loosen: a tsconfig exclude that grew is denied"; else fail "loosen: exclude growth not denied: $(classify "$out")"; fi

# --- pre-commit: staged source goes through the code check ------------------------------
if [ "$SX_NODE" = yes ]; then
  staged "commit: a staged file with an import that names nothing is denied" "src/a.ts" 'import { x } from "./not-here";' deny
  staged "commit: SENIOR_MODE_ALLOW_SYNTAX=1 passes the same commit"         "src/a.ts" 'import { x } from "./not-here";' allow 'SENIOR_MODE_ALLOW_SYNTAX=1 git commit -m x'
  staged "commit: a clean staged file passes"                                "src/a.ts" 'export const x = 1;' allow
else
  ok "commit: (node absent) staged code-check cases skipped"
fi

# --- exit-code-mask-guard: a checker that cannot fail -------------------------------------
masked() { # <name> <command> <want> [<file to create in the repo>]
  local r="$SCRATCH/gx-mask" out got
  newrepo "$r"
  [ -n "${4:-}" ] && put "$r/$4" '{}'
  out=$(cd "$r" && payload "$2" | CLAUDE_PROJECT_DIR="$r" bash "$GX_MASK")
  got=$(classify "$out")
  if [ "$got" = "$3" ]; then ok "$1 -> $got"; else fail "$1 -> got=$got want=$3"; printf '%s\n' "$out" | head -3; fi
}
masked "mask: tsc || true is denied"                      "tsc --noEmit || true" deny
masked "mask: a redirect before || true is still denied"  "npx tsc --noEmit 2>&1 || true" deny
masked "mask: a package script || true is denied"         "pnpm test || true" deny
masked "mask: a later segment || : is denied"             "cd web && pytest -q || :" deny
masked "mask: || echo reports the failure and passes"     "pnpm lint || echo lint failed" silent
masked "mask: the shell's own test builtin passes"        "test -f x || true" silent
masked "mask: a checker's name inside a string passes"    "git commit -m \"run tsc || true later\"" silent
masked "mask: an unrelated || true passes"                "rm -f tmp.log || true" silent
masked "mask: tsc on a file beside a tsconfig is denied"  "npx tsc --noEmit src/a.ts" deny "tsconfig.json"
masked "mask: tsc on a file with no tsconfig passes"      "tsc --noEmit src/a.ts" silent
masked "mask: tsc -p passes"                              "tsc --noEmit -p tsconfig.json" silent "tsconfig.json"
masked "mask: tsc with no files passes"                   "pnpm exec tsc --noEmit" silent "tsconfig.json"
masked "mask: tsx running a script is not tsc"            "tsx scripts/run.ts" silent "tsconfig.json"

# --- check.sh: the receipt -------------------------------------------------------------------
C="$SCRATCH/gx-check"; newrepo "$C"
GD=$(git -C "$C" rev-parse --absolute-git-dir)
out=$(cd "$C" && SENIOR_MODE_TYPECHECK_CMD='echo two errors; exit 3' bash "$HERE/check.sh"); rc=$?
rcpt=$(cat "$GD/senior-mode/receipt-typecheck" 2>/dev/null)
if [ "$rc" -eq 3 ] && [[ "$out" == *"two errors"* ]] && [[ "$out" == *"CHECK_EXIT=3"* ]] && [[ "$rcpt" == rc=3* ]]; then ok "check.sh: a red check exits red, shows its output and writes rc=3"; else fail "check.sh: red run (rc=$rc, receipt=$rcpt): $out"; fi
out=$(cd "$C" && SENIOR_MODE_TYPECHECK_CMD='true' bash "$HERE/check.sh"); rc=$?
rcpt=$(cat "$GD/senior-mode/receipt-typecheck" 2>/dev/null)
if [ "$rc" -eq 0 ] && [[ "$rcpt" == rc=0* ]] && [[ "$rcpt" == *"cmd=true"* ]]; then ok "check.sh: a green check writes rc=0 and the command"; else fail "check.sh: green run (rc=$rc, receipt=$rcpt)"; fi
out=$(cd "$C" && bash "$HERE/check.sh"); rc=$?
if [ "$rc" -eq 2 ] && [[ "$out" == *"no typecheck command is known"* ]]; then ok "check.sh: no command known exits 2 and says how to set one"; else fail "check.sh: unknown command (rc=$rc): $out"; fi
# the command comes from the installed profile when there is one
put "$C/.senior-mode/stacks/ACTIVE" 'demo'
put "$C/.senior-mode/stacks/demo/profile.json" '{ "name": "demo", "commands": { "typecheck": "echo from-the-profile", "test": "<your test command>" } }'
out=$(cd "$C" && bash "$HERE/check.sh")
if [[ "$out" == *"from-the-profile"* ]]; then ok "check.sh: reads the typecheck command from the active stack profile"; else fail "check.sh: profile command not used: $out"; fi
out=$(cd "$C" && bash "$HERE/check.sh" test); rc=$?
if [ "$rc" -eq 2 ]; then ok "check.sh: a profile value that is still a placeholder counts as unset"; else fail "check.sh: placeholder treated as a command (rc=$rc)"; fi

# --- senior-check-after: the receipt line ------------------------------------------------------
RS="gx-receipt-session"
ledger="$TMPDIR/claude-senior-edited-$RS"
receipt="$SCRATCH/gx-receipt"
stop_out() {
  rm -f "$TMPDIR/claude-senior-stop-$RS" "$TMPDIR/claude-senior-undone-$RS" "$TMPDIR/claude-push-done-$RS"
  printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":false}' "$RS" | bash "$GX_STOP"
}
rs_check() { # <name> <output> <needle> <yes|no>
  local g=no; [[ "$2" == *"$3"* ]] && g=yes
  if [ "$g" = "$4" ] && [[ "$2" == *"SENIOR CHECK | AFTER"* ]]; then ok "$1"; else fail "$1 (wanted '$3' present=$4)"; fi
}
rm -f "$ledger" "$receipt"
rs_check "receipt: no edited source, no receipt line" "$(stop_out)" "(6)" no
printf 'receipt=%s\ncheck=%s\n%s\n' "$receipt" "$HERE/check.sh" "src/a.ts" > "$ledger"
rs_check "receipt: edited source and no receipt asks for the full check" "$(stop_out)" "the full typecheck has not run since the last edit" yes
printf 'receipt=%s\ncheck=%s\n%s\n' "$receipt" "$HERE/check.sh" "src/a.ts" > "$ledger"
sleep 1; printf 'rc=0\ntime=1\ncmd=true\n' > "$receipt"
rs_check "receipt: a green receipt newer than the last edit is enough" "$(stop_out)" "(6)" no
printf 'receipt=%s\ncheck=%s\n%s\n' "$receipt" "$HERE/check.sh" "src/a.ts" > "$ledger"
sleep 1; printf 'rc=2\ntime=1\ncmd=false\n' > "$receipt"
rs_check "receipt: a red receipt is called out" "$(stop_out)" "failed with exit code 2" yes
printf 'rc=0\ntime=1\ncmd=true\n' > "$receipt"
sleep 1; printf 'receipt=%s\ncheck=%s\n%s\n' "$receipt" "$HERE/check.sh" "src/a.ts" > "$ledger"
rs_check "receipt: an edit after the receipt makes it stale" "$(stop_out)" "the full typecheck has not run since the last edit" yes
if [ ! -e "$ledger" ]; then fail "receipt: the block cleared the ledger before the turn ended"; else ok "receipt: the ledger survives the block"; fi
printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":false}' "$RS" | bash "$GX_STOP" >/dev/null
if [ ! -e "$ledger" ]; then ok "receipt: the allow that ends the turn clears the ledger"; else fail "receipt: the ledger outlived its turn"; fi
if [ "$SX_NODE" = yes ]; then
  printf 'receipt=%s\ncheck=%s\n%s\n' "$receipt" "$HERE/check.sh" "src/a.ts" > "$ledger"; rm -f "$receipt"
  if stop_out | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{const j=JSON.parse(s);process.exit(j.decision==="block"&&j.reason.includes("(6)")&&!j.reason.includes("\"")?0:1)})' 2>/dev/null; then
    ok "receipt: the block with the receipt line parses as JSON, no double quote"
  else
    fail "receipt: the block with the receipt line is not valid JSON"
  fi
fi
rm -f "$ledger" "$receipt" "$TMPDIR/claude-senior-stop-$RS"
