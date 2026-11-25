#!/usr/bin/env bash
# Cases for the post-edit code check: post-edit-format.sh -> post-edit-check.sh
# -> lib/check-js.mjs, lib/check-py.py and friends.
#
# Sourced by ../test-checklist.sh, which provides ok, fail, FAILS, HERE,
# SCRATCH and TMPDIR. Every case writes a small fixture repo, sends the
# real PostToolUse payload through the real entry point, and reads the
# hook's output. A case names what must be blocked and, beside it, the
# nearest thing that must not be.

SX_FMT="$HERE/post-edit-format.sh"
SX_NODE=no; command -v node >/dev/null 2>&1 && SX_NODE=yes
SX_PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1; then SX_PY="$c"; break; fi
done

put() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }   # <path> <content>
newrepo() { # <dir>: a git repo with one empty commit
  rm -rf "$1"; mkdir -p "$1"; git -C "$1" init -q
  git -C "$1" -c user.email=t@t.t -c user.name=t commit --allow-empty -m init -q
}
edit() { # <file> [VAR=value...]: the hook's output for an edit of that file
  local file="$1"; shift
  printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "${SX_SESSION:-sx-session}" "$file" \
    | env SENIOR_MODE_TYPECHECK=off "$@" bash "$SX_FMT" 2>/dev/null
}
blocks() { # <name> <output> <text the block must carry>
  if [[ "$2" == *'"decision": "block"'* ]] && [[ "$2" == *"$3"* ]]; then ok "$1"
  else fail "$1 (wanted a block carrying: $3)"; printf '%s\n' "$2" | head -6; fi
}
quiet() { # <name> <output>
  if [ -z "$2" ]; then ok "$1"; else fail "$1 (wanted no output)"; printf '%s\n' "$2" | head -6; fi
}

if [ "$SX_NODE" = no ]; then
  ok "code check: (node absent) JS and TS cases skipped"
else
  R="$SCRATCH/sx-js"; newrepo "$R"
  put "$R/package.json" '{"name":"fixture","dependencies":{"left-pad":"1.0.0"},"devDependencies":{"@scope/tool":"1.0.0"}}'
  put "$R/tsconfig.json" '{
  // comments are legal here
  "compilerOptions": { "baseUrl": ".", "paths": { "@/*": ["./src/*"] } },
}'
  mkdir -p "$R/node_modules/installed-only"
  put "$R/yarn.lock" 'locked-only@^1.0.0:
  version "1.0.0"'
  put "$R/src/math.ts" 'export function add(a: number, b: number): number { return a + b; }
export function pick(a: string, b?: string, ...rest: string[]): string { return a; }
export const twice = (n: number, by = 2): number => n * by;
export function over(a: string): string;
export function over(a: number): number;
export function over(a: any): any { return a; }
export type Shape = { w: number };'
  put "$R/src/barrel.ts" 'export * from "./math";
export { add as plus } from "./math";'
  put "$R/src/legacy.js" 'module.exports = { anything: 1 };'
  put "$R/src/widget.ts" 'export default class Widget {}
export const size = 1;'
  put "$R/src/plain.js" 'export function loose(a, b) { return a; }'

  # --- imports that name nothing ---------------------------------------------
  put "$R/src/a1.ts" 'import { thing } from "./missing";'
  blocks "import: a relative path with no file is blocked" "$(edit "$R/src/a1.ts")" "cannot resolve './missing'"
  put "$R/src/a2.ts" 'import { add } from "./math";
import type { Shape } from "./math.js";
import Widget, { size } from "./widget";
console.info(add(1, 2), size, Widget);
export type S = Shape;'
  quiet "import: a file found by extension, a .js specifier for a .ts file, a default import" "$(edit "$R/src/a2.ts")"
  put "$R/src/a3.ts" 'import magic from "totally-invented-pkg";'
  blocks "import: a package nobody declared is blocked" "$(edit "$R/src/a3.ts")" "totally-invented-pkg"
  put "$R/src/a4.ts" 'import pad from "left-pad";
import tool from "@scope/tool/sub/path";
import only from "installed-only";
import locked from "locked-only";
import fs from "node:fs";
import { join } from "path";
import { readFile } from "fs/promises";
import styles from "./a4.module.css?inline";
const lazy = () => import("left-pad");
const old = require("left-pad");'
  put "$R/src/a4.module.css" '.a {}'
  quiet "import: declared, scoped, installed, locked and builtin packages all pass" "$(edit "$R/src/a4.ts")"
  put "$R/src/a5.ts" 'import { add } from "@/math";'
  quiet "import: a tsconfig path alias that resolves" "$(edit "$R/src/a5.ts")"
  put "$R/src/a6.ts" 'import { add } from "@/nowhere/math";'
  blocks "import: a tsconfig path alias with no file behind it is blocked" "$(edit "$R/src/a6.ts")" "@/nowhere/math"
  put "$R/src/a7.ts" 'import x from "virtual:something";
import y from "~/aliased/by/the/bundler";
import z from "$lib/thing";
import w from "./generated/client";'
  quiet "import: virtual modules, bundler aliases and generated paths are left alone" "$(edit "$R/src/a7.ts")"

  # --- named imports the module does not export --------------------------------
  put "$R/src/b1.ts" 'import { subtract } from "./math";'
  blocks "export: a name the module does not export is blocked" "$(edit "$R/src/b1.ts")" "no export named 'subtract'"
  put "$R/src/b2.ts" 'import { add, plus, Shape } from "./barrel";
import { whatever } from "./legacy";
console.info(add, plus, whatever);
export type T = Shape;'
  quiet "export: names through export *, a renamed re-export, and a CommonJS module" "$(edit "$R/src/b2.ts")"
  put "$R/src/b3.ts" 'import Nope from "./math";'
  blocks "export: a default import from a module with no default is blocked" "$(edit "$R/src/b3.ts")" "no default export"

  # --- argument counts -----------------------------------------------------------
  put "$R/src/c1.ts" 'import { add } from "./math";
export const n = add(1, 2, 3);'
  blocks "arity: too many arguments to a repo function is blocked" "$(edit "$R/src/c1.ts")" "add() takes 2 arguments"
  put "$R/src/c2.ts" 'import { plus } from "./barrel";
export const n = plus(1);'
  blocks "arity: too few, through a renamed re-export, is blocked" "$(edit "$R/src/c2.ts")" "this call passes 1"
  put "$R/src/c3.ts" 'import { add, pick, twice, over } from "./math";
import { loose } from "./plain";
export const a = pick("x");
export const b = pick("x", "y", "z", "w");
export const c = twice(2);
export const d = twice(2, 3);
export const e = over(1);
export const f = loose();
export const g = add(...[1, 2] as const);
export const h = add(new Map<string, number>().size, 2);
export function wrap(add: (x: number) => number) { return add(1); }
export const i = [1, 2].map((n) => add(n, n));'
  quiet "arity: optional, default, rest, overloads, a JS declaration, a spread, a generic, a shadowing parameter" "$(edit "$R/src/c3.ts")"
  put "$R/src/c4.ts" 'function area(w: number, h: number): number { return w * h; }
export const x = area(3);'
  blocks "arity: a function declared in the same file is checked too" "$(edit "$R/src/c4.ts")" "area() takes 2 arguments"

  # --- indexes that are always one past the end ------------------------------------
  put "$R/src/d1.ts" 'export function last(items: number[]) { return items[items.length]; }'
  blocks "bounds: arr[arr.length] read is blocked" "$(edit "$R/src/d1.ts")" "one past the last element"
  put "$R/src/d2.ts" 'export function sum(xs: number[]) {
  let t = 0;
  for (let i = 0; i <= xs.length; i++) { t += xs[i]; }
  return t;
}'
  blocks "bounds: a loop to <= length that indexes with it is blocked" "$(edit "$R/src/d2.ts")" "undefined on the last pass"
  put "$R/src/d3.ts" 'export function ok(xs: number[]) {
  xs[xs.length] = 1;
  let t = 0;
  for (let i = 0; i < xs.length; i++) { t += xs[i]; }
  for (let i = 1; i <= xs.length; i++) { t += xs[i - 1]; }
  return t + xs[xs.length - 1];
}'
  quiet "bounds: an append, a < loop, and a 1-based loop pass" "$(edit "$R/src/d3.ts")"

  # --- text that looks like code and is not ------------------------------------------
  put "$R/src/e1.tsx" 'import { add } from "./math";
// import { ghost } from "./nope";
/* import other from "also-not-real"; */
const doc = `import x from "inside-a-template" and ${add(1, 2)} then add(1, 2, 3)`;
const re = /import y from "inside-a-regex"/g;
const text = "add(1, 2, 3, 4) in a string";
export function View() {
  return <p title="it'"'"'s">Don'"'"'t call add(1, 2, 3) here: it'"'"'s text {add(1, 2)} </p>;
}
export const all = [doc, re, text];'
  quiet "lexer: comments, templates, regexes, strings and JSX text are not code" "$(edit "$R/src/e1.tsx")"

  # --- JSON --------------------------------------------------------------------------
  put "$R/data.json" '{ "a": 1, "b": [1, 2 }'
  blocks "json: a broken .json file is blocked" "$(edit "$R/data.json")" "invalid JSON"
  put "$R/settings.json" '{
  // a comment
  "a": 1,
}'
  quiet "json: comments and a trailing comma pass" "$(edit "$R/settings.json")"
fi

# --- Python -----------------------------------------------------------------------------
if [ -z "$SX_PY" ]; then
  ok "code check: (python 3.10+ absent) Python cases skipped"
else
  P="$SCRATCH/sx-py"; newrepo "$P"
  put "$P/uv.lock" 'name = "requests"
name = "pyyaml"'
  put "$P/app/__init__.py" ''
  put "$P/app/util.py" 'LIMIT = 3


def clamp(value, low, high=10, *, strict=False):
    return max(low, min(high, value))


def anything(*args, **kwargs):
    return args'
  put "$P/app/f1.py" 'def broken(:
    pass'
  blocks "python: a syntax error is blocked" "$(edit "$P/app/f1.py")" "syntax error"
  put "$P/app/f2.py" 'import app.nowhere'
  blocks "python: a missing module of a repo package is blocked" "$(edit "$P/app/f2.py")" "no module 'app.nowhere'"
  put "$P/app/f3.py" 'from .util import clamp, MISSING_NAME'
  blocks "python: a name the module does not define is blocked" "$(edit "$P/app/f3.py")" "has no name 'MISSING_NAME'"
  put "$P/app/f4.py" 'import zz_not_a_real_distribution_91x'
  blocks "python: a package in neither the stdlib nor the lockfile is blocked" "$(edit "$P/app/f4.py")" "zz_not_a_real_distribution_91x"
  put "$P/app/f5.py" 'import os
import json as j
import requests
import yaml
from . import util
from .util import clamp, LIMIT
from app.util import anything
import sys

try:
    import zz_optional_speedups
except ImportError:
    zz_optional_speedups = None

if sys.version_info >= (3, 11):
    import tomllib
else:
    import zz_tomli_backport as tomllib

print(os, j, requests, yaml, util, clamp(1, 0), clamp(1, 0, 5, strict=True), LIMIT, anything(1, 2, 3, x=4))'
  quiet "python: stdlib, locked, relative, guarded and version-gated imports pass, and so do good calls" "$(edit "$P/app/f5.py")"
  put "$P/app/f6.py" 'from .util import clamp

a = clamp(1, 2, 3, 4)'
  blocks "python: too many positional arguments is blocked" "$(edit "$P/app/f6.py")" "takes 3 positional arguments"
  put "$P/app/f7.py" 'from .util import clamp

a = clamp(1)
b = clamp(1, 0, stricter=True)'
  out=$(edit "$P/app/f7.py")
  blocks "python: a missing required argument is blocked" "$out" "missing the required argument 'low'"
  blocks "python: a keyword the function does not take is blocked" "$out" "no parameter named 'stricter'"
  put "$P/app/f8.py" 'def tail(xs):
    return xs[len(xs)]


def total(xs):
    t = 0
    for i in range(len(xs) + 1):
        t += xs[i]
    return t


def fine(xs, d):
    d[len(d)] = 1
    return xs[len(xs) - 1] + sum(xs[i] for i in range(len(xs)))'
  out=$(edit "$P/app/f8.py")
  blocks "python: xs[len(xs)] is blocked" "$out" "always out of range"
  blocks "python: range(len(xs) + 1) indexing xs is blocked" "$out" "one pass too many"
  case "$out" in *"f8.py:13"*|*"f8.py:14"*) fail "python: the dict write and the in-range read were flagged" ;; *) ok "python: a dict write at len() and an in-range read pass" ;; esac
fi

# --- shell, modes, the chain ------------------------------------------------------------
S="$SCRATCH/sx-sh"; newrepo "$S"
put "$S/bad.sh" 'if [ -f x ]; then
  echo unterminated'
blocks "shell: bash -n catches an unterminated if" "$(edit "$S/bad.sh")" "syntax error"
put "$S/good.sh" 'if [ -f x ]; then echo ok; fi'
quiet "shell: a valid script passes" "$(edit "$S/good.sh")"
put "$S/notes.md" 'import { nothing } from "./nowhere"'
quiet "modes: a file that is not source is ignored" "$(edit "$S/notes.md")"
quiet "modes: SENIOR_MODE_SYNTAX=off turns the check off" "$(edit "$S/bad.sh" SENIOR_MODE_SYNTAX=off)"
out=$(bash "$HERE/post-edit-check.sh" --plain "$S/bad.sh" "$S/good.sh")
if [[ "$out" == *"syntax error"* ]] && [[ "$out" != *'"decision"'* ]]; then ok "modes: --plain prints the finding lines, no JSON"; else fail "modes: --plain output unexpected: $out"; fi
if [ "$SX_NODE" = yes ]; then
  if edit "$S/bad.sh" | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{const j=JSON.parse(s);process.exit(j.decision==="block"&&j.reason.includes("SENIOR CHECK | CODE")&&!j.reason.includes("\"")?0:1)})' 2>/dev/null; then
    ok "modes: the block parses as JSON and its reason has no double quote"
  else
    fail "modes: the block is not valid JSON, or its reason carries a double quote"
  fi
fi

# --- tier 2: the real checker, inside a budget ---------------------------------------------
T2="$SCRATCH/sx-tier2"; newrepo "$T2"
put "$T2/x.go" 'package main'
put "$T2/fail-check.sh" 'echo "x.go:1:1: undefined: Frobnicate"; exit 1'
put "$T2/pass-check.sh" 'exit 0'
put "$T2/slow-check.sh" 'echo ran >> "$(dirname "$0")/slow-ran"; sleep 6'
SX_SESSION=sx-tier2
rm -f "$TMPDIR/claude-senior-typeslow-$SX_SESSION" "$TMPDIR/claude-senior-edited-$SX_SESSION"
blocks "tier 2: a failing per-file checker is reported" \
  "$(edit "$T2/x.go" SENIOR_MODE_TYPECHECK=on SENIOR_MODE_CHECK_FILE_CMD="bash $T2/fail-check.sh")" "undefined: Frobnicate"
quiet "tier 2: a passing per-file checker says nothing" \
  "$(edit "$T2/x.go" SENIOR_MODE_TYPECHECK=on SENIOR_MODE_CHECK_FILE_CMD="bash $T2/pass-check.sh")"
out=$(edit "$T2/x.go" SENIOR_MODE_TYPECHECK=on SENIOR_MODE_TYPECHECK_BUDGET=1 SENIOR_MODE_CHECK_FILE_CMD="bash $T2/slow-check.sh")
if [[ "$out" == *"did not finish in 1s"* ]] && [[ "$out" != *'"decision"'* ]]; then ok "tier 2: a checker past its budget is stopped and noted, not blocked on"; else fail "tier 2: budget kill not reported: $out"; fi
out=$(edit "$T2/x.go" SENIOR_MODE_TYPECHECK=on SENIOR_MODE_TYPECHECK_BUDGET=1 SENIOR_MODE_CHECK_FILE_CMD="bash $T2/slow-check.sh")
if [[ "$out" == *"off for the rest of this session"* ]]; then ok "tier 2: the second budget kill switches the tier off for the session"; else fail "tier 2: second strike not reported: $out"; fi
runs_before=$(wc -l < "$T2/slow-ran" | tr -d '[:space:]')
edit "$T2/x.go" SENIOR_MODE_TYPECHECK=on SENIOR_MODE_TYPECHECK_BUDGET=1 SENIOR_MODE_CHECK_FILE_CMD="bash $T2/slow-check.sh" >/dev/null
runs_after=$(wc -l < "$T2/slow-ran" | tr -d '[:space:]')
if [ "$runs_before" = "$runs_after" ]; then ok "tier 2: after two strikes the checker is not started again"; else fail "tier 2: the checker ran after two strikes ($runs_before -> $runs_after)"; fi
rm -f "$TMPDIR/claude-senior-typeslow-$SX_SESSION"

# the ledger exists only where a typecheck command is known
rm -f "$TMPDIR/claude-senior-edited-$SX_SESSION"
edit "$T2/x.go" SENIOR_MODE_TYPECHECK=on >/dev/null
if [ ! -e "$TMPDIR/claude-senior-edited-$SX_SESSION" ]; then ok "ledger: no typecheck command, no ledger"; else fail "ledger: written without a typecheck command"; fi
edit "$T2/x.go" SENIOR_MODE_TYPECHECK=on SENIOR_MODE_TYPECHECK_CMD=true >/dev/null
led=$(cat "$TMPDIR/claude-senior-edited-$SX_SESSION" 2>/dev/null)
if [[ "$led" == receipt=*"senior-mode/receipt-typecheck"* ]] && [[ "$led" == *"check="*"check.sh"* ]] && [[ "$led" == *"x.go"* ]]; then ok "ledger: an edit in a repo with a typecheck command is recorded with the receipt path"; else fail "ledger: unexpected contents: $led"; fi
rm -f "$TMPDIR/claude-senior-edited-$SX_SESSION"
unset SX_SESSION

# --- the repo's own TypeScript (runs where the workflow installed it) --------------------------
if [ "$SX_NODE" = yes ] && [ -d "${SM_TEST_TYPESCRIPT:-}" ]; then
  TSR="$SCRATCH/sx-ts"; newrepo "$TSR"
  mkdir -p "$TSR/node_modules"; cp -R "$SM_TEST_TYPESCRIPT" "$TSR/node_modules/typescript"
  put "$TSR/tsconfig.json" '{ "compilerOptions": { "strict": true, "noEmit": true, "target": "es2020", "module": "esnext", "moduleResolution": "bundler" }, "include": ["src"] }'
  put "$TSR/src/lib.ts" 'export function area(w: number, h: number): number { return w * h; }
export class Box { constructor(public w: number) {} scale(by: number): number { return this.w * by; } }'
  put "$TSR/src/t1.ts" 'export const broken = (;'
  blocks "typescript: a syntax error is reported by the repo compiler" "$(edit "$TSR/src/t1.ts")" ": TS1"
  put "$TSR/src/t2.ts" 'import { area, Box } from "./lib";
export const a = area(2, "3");
export const b = new Box(1).scale();'
  out=$(edit "$TSR/src/t2.ts" SENIOR_MODE_TYPECHECK=on)
  blocks "typescript: a wrong argument type is reported by the type tier" "$out" "TS2345"
  blocks "typescript: a wrong argument count on a method is reported by the type tier" "$out" "TS2554"
  put "$TSR/src/t3.ts" 'import { area } from "./lib";
export const a: number = area(2, 3);'
  quiet "typescript: a file that typechecks says nothing" "$(edit "$TSR/src/t3.ts" SENIOR_MODE_TYPECHECK=on)"
  put "$TSR/scripts/outside.ts" 'export const x: number = 1;'
  blocks "typescript: a new file no tsconfig includes is flagged" "$(edit "$TSR/scripts/outside.ts")" "no tsconfig includes this file"
else
  ok "code check: (typescript fixture absent) compiler cases skipped"
fi
