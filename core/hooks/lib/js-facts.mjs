// Reads imports, exports, function signatures, calls and index bounds out
// of a token list from js-lex.mjs. No dependencies, no parser.
//
// Every reader here is conservative. When a shape is ambiguous (an
// overload, a generic call, a destructured export, something that could
// be a method signature) it returns nothing for that item. A missed
// finding costs nothing. A wrong one sends the agent off to fix correct
// code.

import { matchClose } from './js-lex.mjs';

const isP = (t, v) => !!t && t.t === 'p' && t.v === v;
const isId = (t, v) => !!t && t.t === 'id' && (v === undefined || t.v === v);
const OPENERS = new Set(['(', '[', '{', '${']);
const CLOSERS = new Set([')', ']', '}']);
const MODIFIERS = new Set(['declare', 'abstract', 'async']);
const NAMED_DECL = new Set(['class', 'interface', 'type', 'enum', 'namespace', 'module']);
const STATEMENT_START = new Set([
  'export', 'import', 'const', 'let', 'var', 'function', 'class', 'interface',
  'type', 'enum', 'if', 'for', 'while', 'return',
]);
const NOT_A_CALL = new Set([
  'function', 'new', 'class', 'get', 'set', 'static', 'public', 'private',
  'protected', 'abstract', 'override', 'readonly', 'declare', 'async',
]);
const DECL_WORDS = new Set(['const', 'let', 'var', 'function', 'class', 'enum', 'interface', 'type', 'namespace']);
// The only words that can sit right before a call, or right after one, on
// the same line. Any other word there means prose: JSX text that happens
// to spell a call.
const WORD_BEFORE_CALL = new Set([
  'return', 'await', 'yield', 'typeof', 'void', 'delete', 'in', 'of', 'case',
  'else', 'do', 'throw', 'instanceof', 'export', 'default', 'extends',
]);
const WORD_AFTER_CALL = new Set(['as', 'satisfies', 'in', 'of', 'instanceof', 'while']);

// { a, b as c, type D } between the braces at open..close.
// name is the name on the other module's side, local is the name here.
function readNamed(toks, open, close) {
  const out = [];
  let k = open + 1;
  while (k < close) {
    if (isP(toks[k], ',')) { k++; continue; }
    if (isId(toks[k], 'type') && isId(toks[k + 1]) && !isId(toks[k + 1], 'as')) k++;
    const a = toks[k];
    if (!isId(a)) { while (k < close && !isP(toks[k], ',')) k++; continue; }
    let local = a.v;
    k++;
    if (isId(toks[k], 'as') && isId(toks[k + 1])) { local = toks[k + 1].v; k += 2; }
    out.push({ name: a.v, local });
  }
  return out;
}

function readClause(toks, start) {
  let k = start;
  let def = null;
  let ns = false;
  let names = [];
  if (isId(toks[k], 'type') && !isId(toks[k + 1], 'from') && !isP(toks[k + 1], ',')) k++;
  if (isId(toks[k]) && !isId(toks[k], 'from')) {
    def = toks[k].v; k++;
    if (isP(toks[k], ',')) k++;
  }
  if (isP(toks[k], '*')) {
    if (!isId(toks[k + 1], 'as') || !toks[k + 2]) return null;
    ns = true; k += 3;
  } else if (isP(toks[k], '{')) {
    const close = matchClose(toks, k);
    if (close < 0) return null;
    names = readNamed(toks, k, close);
    k = close + 1;
  }
  if (!isId(toks[k], 'from')) return null;
  const s = toks[k + 1];
  if (!s || s.t !== 'str') return null;
  return { spec: s.v, names, def, ns };
}

// Every module specifier the file names: import, export from, require(),
// import(). kind 'export' is a re-export, where names are the source names.
export function importsOf(toks) {
  const out = [];
  for (let i = 0; i < toks.length; i++) {
    const t = toks[i];
    if (t.t !== 'id') continue;
    const prev = toks[i - 1];
    if (isP(prev, '.') || isP(prev, '?.')) continue;
    const next = toks[i + 1];
    if (!next) break;
    if (t.v === 'require') {
      if (isP(next, '(') && toks[i + 2] && toks[i + 2].t === 'str' && isP(toks[i + 3], ')')) {
        out.push({ kind: 'require', spec: toks[i + 2].v, line: t.line, names: [], def: null, ns: false });
      }
    } else if (t.v === 'import') {
      if (next.t === 'str') {
        out.push({ kind: 'import', spec: next.v, line: t.line, names: [], def: null, ns: false });
      } else if (isP(next, '(')) {
        const a = toks[i + 2];
        if (a && a.t === 'str' && (isP(toks[i + 3], ')') || isP(toks[i + 3], ','))) {
          out.push({ kind: 'dynamic', spec: a.v, line: t.line, names: [], def: null, ns: false });
        }
      } else if (!isP(next, '.') && !isP(next, ':')) {
        const clause = readClause(toks, i + 1);
        if (clause) out.push({ kind: 'import', line: t.line, ...clause });
      }
    } else if (t.v === 'export') {
      let k = i + 1;
      if (isId(toks[k], 'type') && (isP(toks[k + 1], '{') || isP(toks[k + 1], '*'))) k++;
      if (isP(toks[k], '*')) {
        let j = k + 1;
        if (isId(toks[j], 'as')) j += 2;
        if (isId(toks[j], 'from') && toks[j + 1] && toks[j + 1].t === 'str') {
          out.push({ kind: 'export', spec: toks[j + 1].v, line: t.line, names: [], def: null, ns: true });
        }
      } else if (isP(toks[k], '{')) {
        const close = matchClose(toks, k);
        if (close > 0 && isId(toks[close + 1], 'from') && toks[close + 2] && toks[close + 2].t === 'str') {
          out.push({ kind: 'export', spec: toks[close + 2].v, line: t.line, names: readNamed(toks, k, close), def: null, ns: false });
        }
      }
    }
  }
  return out;
}

// What a module exports. `unknown` means the list can't be trusted
// (CommonJS, `export =`, a destructured export), so nothing is checked.
// `stars` are the specifiers of `export * from`, and `reexports` maps an
// exported name to the module and name it comes from.
export function exportsOf(toks) {
  const names = new Set();
  const stars = [];
  const reexports = new Map();
  let hasDefault = false;
  let unknown = false;
  let depth = 0;
  for (let i = 0; i < toks.length; i++) {
    const t = toks[i];
    if (t.t === 'p') {
      if (t.v === '{' || t.v === '${') depth++;
      else if (t.v === '}') depth--;
      continue;
    }
    if (t.t !== 'id') continue;
    if (t.v === 'module' && isP(toks[i + 1], '.') && isId(toks[i + 2], 'exports')) { unknown = true; continue; }
    // Any bare `exports` (exports.x, Object.defineProperty(exports, ...)) is CommonJS.
    if (t.v === 'exports' && !isP(toks[i - 1], '.') && !isP(toks[i + 1], ':')) { unknown = true; continue; }
    if (t.v !== 'export' || depth !== 0 || isP(toks[i - 1], '.')) continue;
    let k = i + 1;
    if (!toks[k]) break;
    if (isId(toks[k], 'default')) { hasDefault = true; continue; }
    if (isP(toks[k], '=')) { unknown = true; continue; }
    if (isP(toks[k], '*')) {
      if (isId(toks[k + 1], 'as') && toks[k + 2]) names.add(toks[k + 2].v);
      else if (isId(toks[k + 1], 'from') && toks[k + 2] && toks[k + 2].t === 'str') stars.push(toks[k + 2].v);
      continue;
    }
    if (isId(toks[k], 'type') && isP(toks[k + 1], '{')) k++;
    if (isP(toks[k], '{')) {
      const close = matchClose(toks, k);
      if (close < 0) { unknown = true; continue; }
      const from = isId(toks[close + 1], 'from') && toks[close + 2] && toks[close + 2].t === 'str' ? toks[close + 2].v : null;
      for (const it of readNamed(toks, k, close)) {
        if (it.local === 'default') hasDefault = true; else names.add(it.local);
        if (from) reexports.set(it.local, { spec: from, name: it.name });
      }
      continue;
    }
    while (isId(toks[k]) && MODIFIERS.has(toks[k].v)) k++;
    const kw = toks[k];
    if (!isId(kw)) continue;
    if (kw.v === 'function') {
      k++;
      if (isP(toks[k], '*')) k++;
      if (isId(toks[k])) names.add(toks[k].v);
    } else if (NAMED_DECL.has(kw.v) || kw.v === 'import') {
      if (isId(toks[k + 1])) names.add(toks[k + 1].v);
    } else if (kw.v === 'const' || kw.v === 'let' || kw.v === 'var') {
      k++;
      if (isId(toks[k], 'enum')) { if (isId(toks[k + 1])) names.add(toks[k + 1].v); continue; }
      if (!isId(toks[k])) { unknown = true; continue; }
      names.add(toks[k].v);
      let d = 0;
      for (let j = k + 1; j < toks.length; j++) {
        const u = toks[j];
        if (u.t === 'p') {
          if (OPENERS.has(u.v)) d++;
          else if (CLOSERS.has(u.v)) { d--; if (d < 0) break; }
          else if (d === 0 && u.v === ';') break;
          else if (d === 0 && u.v === ',' && isId(toks[j + 1]) && (isP(toks[j + 2], '=') || isP(toks[j + 2], ':'))) names.add(toks[j + 1].v);
        } else if (u.t === 'id' && d === 0 && u.line > toks[k].line && STATEMENT_START.has(u.v)) break;
      }
    }
  }
  return { names, stars, reexports, hasDefault, unknown };
}

function skipAngles(toks, k) {
  let depth = 0;
  for (let j = k; j < toks.length && j < k + 200; j++) {
    if (isP(toks[j], '<')) depth++;
    else if (isP(toks[j], '>')) { depth--; if (depth === 0) return j + 1; }
    else if (isP(toks[j], ';')) return -1;
  }
  return -1;
}

function isArrowAfter(toks, k) {
  if (isP(toks[k], '=>')) return true;
  if (!isP(toks[k], ':')) return false;
  let d = 0;
  for (let j = k + 1; j < toks.length && j < k + 120; j++) {
    const u = toks[j];
    if (u.t !== 'p') continue;
    if (OPENERS.has(u.v)) d++;
    else if (CLOSERS.has(u.v)) { d--; if (d < 0) return false; }
    else if (d === 0 && u.v === '=>') return true;
    else if (d === 0 && (u.v === ';' || u.v === ',' || u.v === '=')) return false;
  }
  return false;
}

// The parameter list between the parens at open..close, as the fewest and
// the most arguments a call may pass.
function paramsOf(toks, open, close, line) {
  const params = [];
  let cur = null;
  let d = 0;
  let angle = 0;
  let mode = 'name';
  const flush = () => { if (cur) params.push(cur); cur = null; mode = 'name'; angle = 0; };
  for (let k = open + 1; k < close; k++) {
    const u = toks[k];
    if (!cur) cur = { optional: false, hasDefault: false, rest: isP(u, '...'), isThis: isId(u, 'this') };
    if (u.t !== 'p') continue;
    if (OPENERS.has(u.v)) { d++; continue; }
    if (CLOSERS.has(u.v)) { d--; continue; }
    if (d > 0) continue;
    if (mode === 'type') {
      if (u.v === '<') { angle++; continue; }
      if (u.v === '>') { if (angle > 0) angle--; continue; }
    }
    if (angle > 0) continue;
    if (u.v === ',') { flush(); continue; }
    if (mode === 'name' && u.v === '?') { cur.optional = true; continue; }
    if (mode !== 'default' && u.v === ':') { mode = 'type'; continue; }
    if (mode !== 'default' && u.v === '=') { mode = 'default'; cur.hasDefault = true; }
  }
  flush();
  const real = params.filter((p) => !p.isThis);
  let min = 0;
  real.forEach((p, idx) => { if (!p.optional && !p.hasDefault && !p.rest) min = idx + 1; });
  const max = real.some((p) => p.rest) ? Infinity : real.length;
  return { min, max, line };
}

// Top-level functions: name -> list of signatures. More than one entry
// (overloads) or a null entry (unreadable) means callers skip the name.
export function functionsOf(toks) {
  const fns = new Map();
  const add = (name, sig) => { if (!fns.has(name)) fns.set(name, []); fns.get(name).push(sig); };
  const sigAt = (k, line) => {
    if (isP(toks[k], '<')) { k = skipAngles(toks, k); if (k < 0) return null; }
    if (!isP(toks[k], '(')) return undefined;
    const close = matchClose(toks, k);
    return close < 0 ? null : { close, sig: paramsOf(toks, k, close, line) };
  };
  let depth = 0;
  for (let i = 0; i < toks.length; i++) {
    const t = toks[i];
    if (t.t === 'p') {
      if (OPENERS.has(t.v)) depth++;
      else if (CLOSERS.has(t.v)) depth--;
      continue;
    }
    if (t.t !== 'id' || depth !== 0) continue;
    if (t.v === 'function' && !isP(toks[i - 1], '.')) {
      let k = i + 1;
      if (isP(toks[k], '*')) k++;
      const nameTok = toks[k];
      if (!isId(nameTok)) continue;
      const r = sigAt(k + 1, nameTok.line);
      if (r !== undefined) add(nameTok.v, r ? r.sig : null);
    } else if ((t.v === 'const' || t.v === 'let' || t.v === 'var') && isId(toks[i + 1]) && isP(toks[i + 2], '=')) {
      const nameTok = toks[i + 1];
      let k = i + 3;
      if (isId(toks[k], 'async')) k++;
      if (isId(toks[k], 'function')) {
        k++;
        if (isP(toks[k], '*')) k++;
        if (isId(toks[k])) k++;
        const r = sigAt(k, nameTok.line);
        if (r !== undefined) add(nameTok.v, r ? r.sig : null);
      } else {
        const r = sigAt(k, nameTok.line);
        if (r === null) add(nameTok.v, null);
        else if (r && isArrowAfter(toks, r.close + 1)) add(nameTok.v, r.sig);
      }
    }
  }
  return fns;
}

function countArgs(toks, open, close) {
  if (close === open + 1) return 0;
  let d = 0;
  let argc = 0;
  let start = open + 1;
  let lt = false;
  let gt = false;
  for (let k = open + 1; k <= close; k++) {
    const u = toks[k];
    const end = k === close;
    if (!end && u.t === 'p') {
      if (OPENERS.has(u.v)) { d++; continue; }
      if (CLOSERS.has(u.v)) { d--; continue; }
      if (d === 0 && u.v === '<') lt = true;
      if (d === 0 && u.v === '>') gt = true;
    }
    if (!end && !(d === 0 && isP(u, ','))) continue;
    if (k > start) {
      const a = toks[start];
      const b = toks[start + 1];
      if (isP(a, '...')) return -1;
      // `name: Type` or `name?: Type` is a parameter, so this is a signature.
      if (a.t === 'id' && start + 1 < k && (isP(b, ':') || (isP(b, '?') && isP(toks[start + 2], ':')))) return -1;
      argc++;
    } else if (!end) {
      return -1;
    }
    start = k + 1;
  }
  // A `<` and a `>` at the top level could be a generic or JSX, and the
  // commas inside either one are not argument separators.
  return lt && gt ? -1 : argc;
}

// Calls to the given names, as `name(` with a countable argument list.
export function callsOf(toks, names) {
  const out = [];
  for (let i = 0; i < toks.length - 1; i++) {
    const t = toks[i];
    if (t.t !== 'id' || !names.has(t.v) || !isP(toks[i + 1], '(')) continue;
    const prev = toks[i - 1];
    if (prev && prev.t === 'p' && (prev.v === '.' || prev.v === '?.' || prev.v === '#' || prev.v === '@')) continue;
    if (prev && prev.t === 'id' && NOT_A_CALL.has(prev.v)) continue;
    // `word name(` on one line is not an expression. It is JSX text.
    if (prev && prev.t === 'id' && prev.line === t.line && !WORD_BEFORE_CALL.has(prev.v)) continue;
    const close = matchClose(toks, i + 1);
    if (close < 0) continue;
    const after = toks[close + 1];
    // name(...) { is a method, name(...): is a signature or a ternary arm.
    if (after && after.t === 'p' && (after.v === '{' || after.v === ':' || after.v === '=>')) continue;
    // `name(...) word` on one line is JSX text too.
    if (after && after.t === 'id' && after.line === toks[close].line && !WORD_AFTER_CALL.has(after.v)) continue;
    const argc = countArgs(toks, i + 1, close);
    if (argc >= 0) out.push({ name: t.v, argc, line: t.line });
  }
  return out;
}

// Names the file binds a second time: a declaration, an arrow parameter,
// or a parameter of any function. A call to one of those may not reach
// the import, so the argument check leaves the name alone.
export function reboundNames(toks) {
  const seen = new Map();
  const bump = (n) => seen.set(n, (seen.get(n) || 0) + 1);
  for (let i = 0; i < toks.length; i++) {
    const t = toks[i];
    if (t.t !== 'id') continue;
    const prev = toks[i - 1];
    const next = toks[i + 1];
    if (isId(prev) && DECL_WORDS.has(prev.v)) { bump(t.v); continue; }
    if (isP(prev, '*') && isId(toks[i - 2], 'function')) { bump(t.v); continue; }
    if (isP(next, '=>')) { bump(t.v); continue; }
    if ((isP(prev, '(') || isP(prev, ',')) && next && next.t === 'p' && (next.v === ',' || next.v === ')' || next.v === ':' || next.v === '=' || next.v === '?')) {
      let d = 0;
      let open = -1;
      for (let k = i - 1; k >= 0 && k > i - 400; k--) {
        const u = toks[k];
        if (u.t !== 'p') continue;
        if (CLOSERS.has(u.v)) d++;
        else if (OPENERS.has(u.v)) { if (d === 0) { open = u.v === '(' ? k : -1; break; } d--; }
      }
      if (open < 0) continue;
      const close = matchClose(toks, open);
      const after = close > 0 ? toks[close + 1] : null;
      if (after && after.t === 'p' && (after.v === '=>' || after.v === '{' || after.v === ':')) bump(t.v);
    }
  }
  return seen;
}
