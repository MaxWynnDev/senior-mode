// Post-edit checks for JavaScript and TypeScript files. Needs `node` and
// nothing else: no package, no compiler, no node_modules.
//
//   node check-js.mjs <repo-root> <file>...
//
// For each file it reports
//   - an import that names nothing: no file, no declared package, no alias
//   - a named import the target module does not export
//   - a call to a function declared in a .ts file of this repo with too
//     few or too many arguments
//   - two index shapes that always read one past the end
//
// One finding per line on stdout: `<path>:<line>: <message>`. Exit 1 when
// there is at least one finding, 0 otherwise. Any failure of the checker
// itself prints nothing and exits 0: a broken check must not block an edit
// that already happened.

import fs from 'node:fs';
import path from 'node:path';
import { lex } from './js-lex.mjs';
import { importsOf, exportsOf, functionsOf, callsOf, reboundNames } from './js-facts.mjs';
import { boundsOf } from './js-bounds.mjs';
import { makeResolver } from './js-resolve.mjs';

const SOURCE = /\.(ts|tsx|mts|cts|js|jsx|mjs|cjs)$/;
const TYPED = /\.(ts|tsx|mts|cts)$/;
const MAX_BYTES = 600 * 1024;
const MAX_FINDINGS = 30;

const norm = (p) => p.replace(/\\/g, '/');
// The canonical path. A temp dir reached through a symlink (macOS /var)
// or a Windows short name would otherwise not sit under the repo root.
const real = (p) => {
  try { return norm(fs.realpathSync.native(path.resolve(p))); } catch { return norm(path.resolve(p)); }
};

function main() {
  const [root, ...files] = process.argv.slice(2);
  if (!root || !files.length) return 0;
  const rootAbs = real(root);
  const resolve = makeResolver(rootAbs);
  const cache = new Map();
  const findings = [];

  const rel = (file) => {
    const r = norm(path.relative(rootAbs, file));
    return r && !r.startsWith('..') ? r : norm(file);
  };

  // Tokens and facts for one file, read once per run.
  const factsOf = (file) => {
    const key = norm(path.resolve(file));
    if (cache.has(key)) return cache.get(key);
    let facts = null;
    try {
      const stat = fs.statSync(key);
      if (stat.isFile() && stat.size <= MAX_BYTES) {
        const { toks, unsure } = lex(fs.readFileSync(key, 'utf8'));
        facts = { file: key, toks, unsure, exports: exportsOf(toks), functions: functionsOf(toks) };
      }
    } catch { /* unreadable: no facts */ }
    cache.set(key, facts);
    return facts;
  };

  // Does `file` export `name`? true, false, or null when it can't be known.
  const exportsName = (file, name, depth, seen) => {
    if (depth > 4 || seen.has(file) || !SOURCE.test(file) || file.endsWith('.d.ts')) return null;
    seen.add(file);
    const facts = factsOf(file);
    if (!facts || facts.unsure || facts.exports.unknown) return null;
    const ex = facts.exports;
    if (name === 'default' ? ex.hasDefault : ex.names.has(name)) return true;
    let anyUnknown = false;
    for (const spec of ex.stars) {
      const r = resolve(file, spec);
      if (!r.ok) continue;
      if (!r.file) { anyUnknown = true; continue; }
      const sub = exportsName(norm(r.file), name, depth + 1, seen);
      if (sub === true) return true;
      if (sub === null) anyUnknown = true;
    }
    return anyUnknown ? null : false;
  };

  // The one readable signature of `name`, following re-exports to where
  // it is declared. Only a declaration in a .ts file counts: plain
  // JavaScript lets a call pass any number of arguments.
  const signatureOf = (file, name, depth, seen) => {
    if (depth > 4 || seen.has(file) || !TYPED.test(file) || file.endsWith('.d.ts')) return null;
    seen.add(file);
    const facts = factsOf(file);
    if (!facts || facts.unsure) return null;
    const sigs = facts.functions.get(name);
    if (sigs) {
      if (sigs.length !== 1 || !sigs[0]) return null;
      if ((reboundNames(facts.toks).get(name) || 0) !== 1) return null;
      return { ...sigs[0], file };
    }
    const re = facts.exports.reexports.get(name);
    if (re) {
      const r = resolve(file, re.spec);
      return r.ok && r.file ? signatureOf(norm(r.file), re.name, depth + 1, seen) : null;
    }
    for (const spec of facts.exports.stars) {
      const r = resolve(file, spec);
      if (!r.ok || !r.file) continue;
      const sub = signatureOf(norm(r.file), name, depth + 1, seen);
      if (sub) return sub;
    }
    return null;
  };

  for (const arg of files) {
    const file = real(arg);
    if (!SOURCE.test(file) || file.endsWith('.d.ts')) continue;
    const facts = factsOf(file);
    if (!facts) continue;
    const here = rel(file);
    const add = (line, msg) => { if (findings.length < MAX_FINDINGS) findings.push(`${here}:${line}: ${msg}`); };
    const callable = new Map(); // local name -> signature

    for (const imp of importsOf(facts.toks)) {
      const r = resolve(file, imp.spec);
      if (!r.ok) { add(imp.line, `cannot resolve '${imp.spec}': ${r.why}.`); continue; }
      if (r.unknown || !r.file) continue;
      const target = norm(r.file);
      if (!SOURCE.test(target) || target.endsWith('.d.ts')) continue;
      const wanted = imp.names.map((n) => ({ name: n.name, local: n.local }));
      if (imp.def && imp.kind === 'import') wanted.push({ name: 'default', local: imp.def });
      for (const w of wanted) {
        const has = exportsName(target, w.name, 0, new Set());
        if (has === false) {
          const tf = factsOf(target);
          const list = tf ? [...tf.exports.names].slice(0, 8).join(', ') : '';
          const what = w.name === 'default' ? 'no default export' : `no export named '${w.name}'`;
          add(imp.line, `'${imp.spec}' has ${what}${list ? ` (it exports: ${list})` : ''}.`);
        } else if (has === true && imp.kind === 'import' && w.name !== 'default' && !facts.unsure) {
          const sig = signatureOf(target, w.name, 0, new Set());
          if (sig) callable.set(w.local, sig);
        }
      }
    }
    if (facts.unsure) continue;

    const rebound = reboundNames(facts.toks);
    if (TYPED.test(file)) {
      for (const [name, sigs] of facts.functions) {
        if (sigs.length === 1 && sigs[0] && rebound.get(name) === 1 && !callable.has(name)) callable.set(name, { ...sigs[0], file });
      }
    }
    for (const [name, sig] of [...callable]) {
      // An imported name the file binds again may not be the import here.
      if (sig.file !== file && rebound.get(name)) callable.delete(name);
    }
    for (const call of callsOf(facts.toks, new Set(callable.keys()))) {
      const sig = callable.get(call.name);
      if (call.argc >= sig.min && call.argc <= sig.max) continue;
      const want = sig.max === Infinity ? `at least ${sig.min}` : sig.min === sig.max ? `${sig.min}` : `${sig.min} to ${sig.max}`;
      add(call.line, `${call.name}() takes ${want} argument${want === '1' ? '' : 's'} (declared at ${rel(sig.file)}:${sig.line}), and this call passes ${call.argc}.`);
    }
    for (const b of boundsOf(facts.toks)) add(b.line, b.msg);
  }

  if (findings.length) process.stdout.write(findings.join('\n') + '\n');
  return findings.length ? 1 : 0;
}

let code = 0;
try { code = main(); } catch { code = 0; }
process.exit(code);
