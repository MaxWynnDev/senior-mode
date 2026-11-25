// Resolves an import specifier the way a JS or TS project would, far
// enough to answer one question: does this name anything that exists?
//
// It reads the disk, the nearest tsconfig or jsconfig, the package.json
// files between the importing file and the repo root, node_modules when
// it is there, and the lockfile. It never runs project code.
//
// Three answers: { ok: true, file } for a repo file, { ok: true } for a
// package or a builtin, { ok: false, why } when nothing in the repo
// accounts for the name. Anything it can't decide (a bundler alias with
// no tsconfig entry, a virtual module, a generated path) is { ok: true,
// unknown: true }: unknown is never reported.

import fs from 'node:fs';
import path from 'node:path';
import { builtinModules } from 'node:module';

const CODE_EXTS = ['.ts', '.tsx', '.mts', '.cts', '.js', '.jsx', '.mjs', '.cjs'];
const OTHER_EXTS = ['.json', '.d.ts', '.vue', '.svelte', '.astro', '.node'];
const TS_FOR_JS = { '.js': ['.ts', '.tsx'], '.jsx': ['.tsx'], '.mjs': ['.mts'], '.cjs': ['.cts'] };
const GENERATED = new Set([
  'generated', '__generated__', 'gen', 'dist', 'build', 'out', '.next', '.nuxt',
  '.svelte-kit', '.astro', '.output', '.turbo', 'coverage',
]);
const NPM_NAME = /^(@[a-z0-9-~][a-z0-9-._~]*\/)?[a-z0-9-~][a-z0-9-._~]*$/;
const DEP_KEYS = ['dependencies', 'devDependencies', 'peerDependencies', 'optionalDependencies', 'bundledDependencies', 'bundleDependencies'];
const LOCKFILES = ['pnpm-lock.yaml', 'package-lock.json', 'yarn.lock', 'bun.lock', 'npm-shrinkwrap.json'];

const isFile = (p) => { try { return fs.statSync(p).isFile(); } catch { return false; } };
const isDir = (p) => { try { return fs.statSync(p).isDirectory(); } catch { return false; } };
const norm = (p) => p.replace(/\\/g, '/');

// JSON with comments and trailing commas allowed (tsconfig style). Null
// when the file is missing or broken even by that reading.
export function readJsonLoose(file) {
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return null; }
  try { return JSON.parse(text); } catch { /* fall through to the comment-tolerant read */ }
  let out = '';
  let i = 0;
  const n = text.length;
  while (i < n) {
    const c = text[i];
    if (c === '"') {
      let k = i + 1;
      while (k < n && text[k] !== '"') k += text[k] === '\\' ? 2 : 1;
      out += text.slice(i, k + 1); i = k + 1; continue;
    }
    if (c === '/' && text[i + 1] === '/') { while (i < n && text[i] !== '\n') i++; continue; }
    if (c === '/' && text[i + 1] === '*') { const e = text.indexOf('*/', i + 2); i = e < 0 ? n : e + 2; continue; }
    out += c; i++;
  }
  try { return JSON.parse(out.replace(/,(\s*[}\]])/g, '$1')); } catch { return null; }
}

export function makeResolver(root) {
  const rootAbs = norm(path.resolve(root));
  const pkgCache = new Map();
  const cfgCache = new Map();
  let workspaceNames = null;
  let lockText = null;
  let ambient = null;

  const pkgAt = (dir) => {
    if (!pkgCache.has(dir)) pkgCache.set(dir, isFile(dir + '/package.json') ? readJsonLoose(dir + '/package.json') || {} : null);
    return pkgCache.get(dir);
  };
  // The directories from the importing file up to the repo root. A file
  // outside the root walks to the top of the disk.
  const dirsUp = (fromDir) => {
    const out = [];
    let d = norm(fromDir);
    for (let guard = 0; guard < 60; guard++) {
      out.push(d);
      if (d === rootAbs) break;
      const parent = norm(path.dirname(d));
      if (parent === d) break;
      d = parent;
    }
    return out;
  };

  function fileCandidate(base) {
    if (isFile(base)) return base;
    const ext = path.extname(base);
    if (TS_FOR_JS[ext]) {
      const stem = base.slice(0, -ext.length);
      for (const e of TS_FOR_JS[ext]) if (isFile(stem + e)) return stem + e;
    }
    for (const e of CODE_EXTS) if (isFile(base + e)) return base + e;
    for (const e of OTHER_EXTS) if (isFile(base + e)) return base + e;
    if (isDir(base)) {
      for (const e of CODE_EXTS) if (isFile(base + '/index' + e)) return base + '/index' + e;
      if (isFile(base + '/index.d.ts')) return base + '/index.d.ts';
      if (isFile(base + '/package.json')) return base + '/package.json';
    }
    return null;
  }

  function configFor(fromDir) {
    for (const d of dirsUp(fromDir)) {
      for (const name of ['tsconfig.json', 'jsconfig.json']) {
        const file = d + '/' + name;
        if (!isFile(file)) continue;
        if (!cfgCache.has(file)) cfgCache.set(file, loadConfig(file, 0));
        return cfgCache.get(file);
      }
    }
    return null;
  }
  // paths and baseUrl, following a relative `extends` up to three levels.
  function loadConfig(file, depth) {
    const json = readJsonLoose(file);
    if (!json) return { broken: true };
    const dir = norm(path.dirname(file));
    const co = json.compilerOptions || {};
    let paths = co.paths || null;
    let baseUrl = co.baseUrl ? norm(path.resolve(dir, co.baseUrl)) : null;
    let pathsBase = baseUrl || dir;
    let external = false;
    const parents = [].concat(json.extends || []);
    for (const ext of parents) {
      if (typeof ext !== 'string') continue;
      if (!ext.startsWith('.') || depth >= 3) { external = true; continue; }
      let target = norm(path.resolve(dir, ext));
      if (!isFile(target) && isFile(target + '.json')) target += '.json';
      if (!isFile(target)) { external = true; continue; }
      const up = loadConfig(target, depth + 1);
      if (up.broken) { external = true; continue; }
      if (!paths && up.paths) { paths = up.paths; pathsBase = up.pathsBase; }
      if (!baseUrl && up.baseUrl) baseUrl = up.baseUrl;
      if (up.external) external = true;
    }
    return { paths, pathsBase, baseUrl, external };
  }

  function viaAlias(fromDir, spec) {
    const cfg = configFor(fromDir);
    if (!cfg) return null;
    if (cfg.broken) return { ok: true, unknown: true };
    for (const [pattern, targets] of Object.entries(cfg.paths || {})) {
      const star = pattern.indexOf('*');
      let captured = null;
      if (star < 0) { if (pattern === spec) captured = ''; } else {
        const pre = pattern.slice(0, star);
        const post = pattern.slice(star + 1);
        if (spec.startsWith(pre) && spec.endsWith(post) && spec.length >= pre.length + post.length) {
          captured = spec.slice(pre.length, spec.length - post.length);
        }
      }
      if (captured === null) continue;
      for (const target of [].concat(targets || [])) {
        const hit = fileCandidate(norm(path.resolve(cfg.pathsBase, String(target).replace('*', captured))));
        if (hit) return { ok: true, file: hit };
      }
      // No target exists. TypeScript falls back to normal resolution here,
      // so the caller decides: a name that can only be an alias is
      // unresolved, a name that could be a package gets the package check.
      // A config that extends a package may map the alias somewhere else.
      return { miss: pattern, external: cfg.external };
    }
    if (cfg.baseUrl) {
      const hit = fileCandidate(cfg.baseUrl + '/' + spec);
      if (hit) return { ok: true, file: hit };
    }
    return null;
  }

  function loadWorkspaceNames() {
    workspaceNames = new Set();
    const rootPkg = pkgAt(rootAbs);
    if (!isFile(rootAbs + '/pnpm-workspace.yaml') && !(rootPkg && rootPkg.workspaces) && !isFile(rootAbs + '/lerna.json')) return;
    let scanned = 0;
    const visit = (dir, depth) => {
      if (depth > 3 || scanned > 400) return;
      let entries;
      try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
      for (const e of entries) {
        if (!e.isDirectory() || e.name === 'node_modules' || e.name.startsWith('.')) continue;
        const sub = dir + '/' + e.name;
        scanned++;
        const p = pkgAt(sub);
        if (p && p.name) workspaceNames.add(p.name);
        visit(sub, depth + 1);
      }
    };
    visit(rootAbs, 1);
  }

  function inLockfile(pkg) {
    if (lockText === null) {
      lockText = '';
      for (const name of LOCKFILES) {
        // The leading newline lets a package on the file's first line match too.
        try { lockText += '\n' + fs.readFileSync(rootAbs + '/' + name, 'utf8'); } catch { /* not this one */ }
      }
    }
    if (!lockText) return false;
    return [`/${pkg}@`, `"${pkg}@`, `'${pkg}@`, `\n${pkg}@`, `node_modules/${pkg}"`, `"${pkg}":`, `'${pkg}':`, `\n      ${pkg}:`, `\n  ${pkg}@`]
      .some((needle) => lockText.includes(needle));
  }

  // `declare module 'x'` in the repo's own .d.ts files, wildcards included.
  function declaredAmbient(spec) {
    if (ambient === null) {
      ambient = [];
      let seen = 0;
      const visit = (dir, depth) => {
        if (depth > 4 || seen > 150) return;
        let entries;
        try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
        for (const e of entries) {
          if (e.name === 'node_modules' || e.name === '.git' || GENERATED.has(e.name)) continue;
          const p = dir + '/' + e.name;
          if (e.isDirectory()) { visit(p, depth + 1); continue; }
          if (!e.name.endsWith('.d.ts')) continue;
          seen++;
          let text = '';
          try { text = fs.readFileSync(p, 'utf8'); } catch { continue; }
          const re = /declare\s+module\s+['"]([^'"]+)['"]/g;
          let m;
          while ((m = re.exec(text))) ambient.push(m[1]);
        }
      };
      visit(rootAbs, 1);
    }
    return ambient.some((pat) => {
      if (pat === spec) return true;
      const star = pat.indexOf('*');
      return star >= 0 && spec.startsWith(pat.slice(0, star)) && spec.endsWith(pat.slice(star + 1));
    });
  }

  function viaPackage(fromDir, spec) {
    const parts = spec.split('/');
    const pkg = spec.startsWith('@') ? parts.slice(0, 2).join('/') : parts[0];
    if (builtinModules.includes(spec) || builtinModules.includes(pkg)) return { ok: true };
    if (!NPM_NAME.test(pkg)) return { ok: true, unknown: true };
    if (isFile(rootAbs + '/deno.json') || isFile(rootAbs + '/deno.jsonc')) return { ok: true, unknown: true };
    let sawManifest = null;
    for (const d of dirsUp(fromDir)) {
      if (isDir(d + '/node_modules/' + pkg)) return { ok: true };
      // A bare `components/Button` that is really a folder beside the code.
      if (isDir(d + '/' + parts[0]) || isDir(d + '/src/' + parts[0])) return { ok: true, unknown: true };
      const p = pkgAt(d);
      if (!p) continue;
      sawManifest = sawManifest || d + '/package.json';
      if (p.name === pkg) return { ok: true };
      for (const key of DEP_KEYS) {
        const deps = p[key];
        if (!deps) continue;
        if (Array.isArray(deps) ? deps.includes(pkg) : (pkg in deps || ('@types/' + pkg.replace('@', '').replace('/', '__')) in deps)) return { ok: true };
      }
    }
    if (!sawManifest) return { ok: true, unknown: true };
    if (workspaceNames === null) loadWorkspaceNames();
    if (workspaceNames.has(pkg)) return { ok: true };
    if (inLockfile(pkg)) return { ok: true };
    if (declaredAmbient(spec) || declaredAmbient(pkg)) return { ok: true };
    const rel = norm(path.relative(rootAbs, sawManifest)) || 'package.json';
    return { ok: false, why: `"${pkg}" is not in ${rel}, not in node_modules, not in the lockfile, and no tsconfig path maps it` };
  }

  return function resolve(fromFile, rawSpec) {
    const spec = String(rawSpec).replace(/[?#].*$/, '');
    const fromDir = norm(path.dirname(path.resolve(fromFile)));
    if (!spec) return { ok: true, unknown: true };
    if (spec.startsWith('.') || spec.startsWith('/')) {
      const base = spec.startsWith('/') ? null : norm(path.resolve(fromDir, spec));
      if (!base) return { ok: true, unknown: true };
      const hit = fileCandidate(base);
      if (hit) return { ok: true, file: hit };
      if (spec.split('/').some((seg) => GENERATED.has(seg))) return { ok: true, unknown: true };
      return { ok: false, why: `no file at ${norm(path.relative(rootAbs, base)) || spec} (tried the usual extensions and /index)` };
    }
    if (/^[a-z][a-z0-9+.-]*:/i.test(spec)) return { ok: true, unknown: !spec.startsWith('node:') };
    const alias = viaAlias(fromDir, spec);
    if (alias && alias.ok !== undefined) return alias;
    const first = spec.startsWith('@') ? spec.split('/').slice(0, 2).join('/') : spec.split('/')[0];
    const aliasOnly = /^[#$~]/.test(spec) || spec.startsWith('@/') || !NPM_NAME.test(first);
    if (alias && alias.miss && aliasOnly) {
      if (alias.external) return { ok: true, unknown: true };
      return { ok: false, why: `the tsconfig path "${alias.miss}" matches it, and no file exists at the target` };
    }
    if (aliasOnly) return { ok: true, unknown: true };
    return viaPackage(fromDir, spec);
  };
}
