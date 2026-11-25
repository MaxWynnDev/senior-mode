// Runs the repo's own TypeScript compiler on the files that were just
// edited. It uses the `typescript` package the repo already installed
// (found from each file's folder). A repo without it gets nothing from
// this script and no error.
//
//   node check-ts-types.mjs <repo-root> <file>...            syntax, then types
//   node check-ts-types.mjs <repo-root> --syntax <file>...   syntax only
//   node check-ts-types.mjs <repo-root> --covered <file>...  is each file in a tsconfig?
//
// Types mode builds a program for the one file under the options of the
// tsconfig that includes it, with the project's .d.ts files as extra
// roots so ambient declarations resolve. It reports that file's
// diagnostics only. Errors the edit caused in other files are the full
// typecheck's job.
//
// One finding per line: `<path>:<line>:<col>: TS<code> <message>`. Exit 1
// with findings, 0 without. Any failure of this script prints nothing and
// exits 0.

import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const TS_FILE = /\.(ts|tsx|mts|cts)$/;
const JS_FILE = /\.(js|jsx|mjs|cjs)$/;
const MAX_LINES = 20;
const norm = (p) => p.replace(/\\/g, '/');

function loadTypescript(fromFile) {
  try { return createRequire(fromFile)('typescript'); } catch { return null; }
}

function main() {
  const argv = process.argv.slice(2);
  const root = argv.shift();
  let mode = 'types';
  if (argv[0] === '--syntax') { mode = 'syntax'; argv.shift(); }
  else if (argv[0] === '--covered') { mode = 'covered'; argv.shift(); }
  if (!root || !argv.length) return 0;
  // Canonical paths: a symlinked temp dir or a Windows short name would
  // otherwise never match the names the compiler reports.
  const real = (p) => {
    try { return norm(fs.realpathSync.native(path.resolve(p))); } catch { return norm(path.resolve(p)); }
  };
  const rootAbs = real(root);
  const out = [];
  const rel = (file) => {
    const r = norm(path.relative(rootAbs, file));
    return r && !r.startsWith('..') ? r : norm(file);
  };
  const same = (a, b) => (process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b);
  const configs = new Map();

  for (const arg of argv) {
    const file = real(arg);
    if (!(TS_FILE.test(file) || JS_FILE.test(file)) || file.endsWith('.d.ts')) continue;
    const ts = loadTypescript(file);
    if (!ts) continue;

    const report = (diags) => {
      for (const d of diags) {
        if (out.length >= MAX_LINES) break;
        if (!d.file || !same(norm(d.file.fileName), file)) continue;
        const pos = d.file.getLineAndCharacterOfPosition(d.start || 0);
        const msg = ts.flattenDiagnosticMessageText(d.messageText, ' ').replace(/\s+/g, ' ');
        out.push(`${rel(file)}:${pos.line + 1}:${pos.character + 1}: TS${d.code} ${msg}`);
      }
    };

    // Parse the tsconfig at `cfgPath`, once per run. The include walk is
    // the slow part on a big repo.
    const parse = (cfgPath) => {
      if (configs.has(cfgPath)) return configs.get(cfgPath);
      let parsed = null;
      try {
        const raw = ts.readConfigFile(cfgPath, ts.sys.readFile);
        if (!raw.error) parsed = ts.parseJsonConfigFileContent(raw.config, ts.sys, path.dirname(cfgPath), undefined, cfgPath);
      } catch { parsed = null; }
      configs.set(cfgPath, parsed);
      return parsed;
    };
    const includes = (parsed) => !!parsed && parsed.fileNames.some((f) => same(norm(f), file));

    // The tsconfig that includes the file: the nearest one walking up, a
    // sibling tsconfig.*.json, or a project it references.
    const owner = () => {
      let dir = norm(path.dirname(file));
      let nearest = null;
      for (let guard = 0; guard < 40; guard++) {
        let names = [];
        try { names = fs.readdirSync(dir).filter((n) => /^tsconfig(\..+)?\.json$/.test(n)); } catch { names = []; }
        names.sort((a, b) => (a === 'tsconfig.json' ? -1 : b === 'tsconfig.json' ? 1 : a.localeCompare(b)));
        for (const name of names) {
          const cfgPath = dir + '/' + name;
          nearest = nearest || cfgPath;
          const parsed = parse(cfgPath);
          if (includes(parsed)) return { cfgPath, parsed, nearest };
          for (const ref of (parsed && parsed.projectReferences) || []) {
            let refPath = norm(ref.path);
            try { if (fs.statSync(refPath).isDirectory()) refPath += '/tsconfig.json'; } catch { continue; }
            const sub = parse(refPath);
            if (includes(sub)) return { cfgPath: refPath, parsed: sub, nearest };
          }
        }
        if (dir === rootAbs) break;
        const up = norm(path.dirname(dir));
        if (up === dir) break;
        dir = up;
      }
      return { cfgPath: null, parsed: null, nearest };
    };

    if (mode === 'covered') {
      if (!TS_FILE.test(file)) continue;
      const o = owner();
      if (!o.cfgPath && o.nearest) {
        out.push(`${rel(file)}:1: no tsconfig includes this file (nearest: ${rel(o.nearest)}), so the type checker never sees it. Add it to an include, or move it under one.`);
      }
      continue;
    }

    if (mode === 'syntax') {
      const options = { noResolve: true, noLib: true, allowJs: true, checkJs: false, jsx: ts.JsxEmit.Preserve, noEmit: true };
      const program = ts.createProgram([file], options);
      const sf = program.getSourceFile(file);
      if (sf) report(program.getSyntacticDiagnostics(sf));
      continue;
    }

    // types
    if (!TS_FILE.test(file)) continue;
    const o = owner();
    if (!o.parsed) continue; // no tsconfig covers it: nothing to check it against
    const dts = o.parsed.fileNames.filter((f) => f.endsWith('.d.ts'));
    const options = { ...o.parsed.options, noEmit: true, incremental: false, composite: false, declaration: false, declarationMap: false, tsBuildInfoFile: undefined };
    const program = ts.createProgram({ rootNames: [file, ...dts], options });
    const sf = program.getSourceFile(file);
    if (!sf) continue;
    const syntactic = program.getSyntacticDiagnostics(sf);
    report(syntactic.length ? syntactic : program.getSemanticDiagnostics(sf));
  }

  if (out.length) process.stdout.write(out.join('\n') + '\n');
  return out.length ? 1 : 0;
}

let code = 0;
try { code = main(); } catch { code = 0; }
process.exit(code);
