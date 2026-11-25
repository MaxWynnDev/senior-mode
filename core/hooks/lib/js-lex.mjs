// Tokenizer for JavaScript and TypeScript source. No dependencies.
//
// The post-edit checks read imports, exports and calls. To do that
// without a parser they need to know what is code and what is the inside
// of a string, a comment, a template or a regex literal. This splits a
// file into tokens and nothing more.
//
// When it can't tokenize a file cleanly (an unclosed comment or
// template, brackets that don't balance) it returns `unsure: true`.
// Callers then keep the import checks, which read statements from the
// top of the file, and skip every check that depends on call sites.
//
// Token: { t: 'id' | 'str' | 'num' | 'p' | 'tpl' | 're', v, line }

const P3 = new Set(['===', '!==', '...', '**=', '&&=', '||=', '??=']);
const P2 = new Set([
  '=>', '==', '!=', '<=', '>=', '&&', '||', '??', '?.', '++', '--',
  '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '**',
]);
// A `/` after one of these words starts a regex, not a division.
const RE_PREV = new Set([
  'return', 'typeof', 'instanceof', 'in', 'of', 'new', 'delete', 'void',
  'throw', 'case', 'do', 'else', 'yield', 'await',
]);
const ID_START = /[A-Za-z_$ -￿]/;
const ID_PART = /[A-Za-z0-9_$ -￿]/;
const NUM_PART = /[0-9A-Za-z_.]/;

export function lex(src) {
  const toks = [];
  const n = src.length;
  const open = []; // bracket stack: '(', '[', '{' or '${'
  let i = 0;
  let line = 1;
  let unsure = false;
  const push = (t, v) => { toks.push({ t, v, line }); };

  const regexOk = () => {
    const p = toks[toks.length - 1];
    if (!p) return true;
    if (p.t === 'p') {
      // `<` is left out: `</div>` in JSX is far more common than `a < /re/`.
      return !(p.v === ')' || p.v === ']' || p.v === '}' || p.v === '<' || p.v === '++' || p.v === '--');
    }
    if (p.t === 'id') return RE_PREV.has(p.v);
    return false;
  };

  // Reads template text from i up to the closing backtick or the next ${.
  const template = () => {
    let s = '';
    while (i < n) {
      const c = src[i];
      if (c === '\\') { s += src.substr(i, 2); i += 2; continue; }
      if (c === '`') { i++; push('tpl', s); return; }
      if (c === '$' && src[i + 1] === '{') {
        i += 2; push('tpl', s); push('p', '${'); open.push('${');
        return;
      }
      if (c === '\n') line++;
      s += c; i++;
    }
    unsure = true;
  };

  while (i < n) {
    const c = src[i];
    if (c === '\n') { line++; i++; continue; }
    if (c <= ' ' || c === '﻿') { i++; continue; }
    const d = src[i + 1];

    if (c === '/' && d === '/') { while (i < n && src[i] !== '\n') i++; continue; }
    if (c === '/' && d === '*') {
      const end = src.indexOf('*/', i + 2);
      const stop = end < 0 ? n : end + 2;
      for (let k = i; k < stop; k++) if (src[k] === '\n') line++;
      if (end < 0) unsure = true;
      i = stop; continue;
    }
    if (c === '#' && d === '!' && i === 0) { while (i < n && src[i] !== '\n') i++; continue; }

    // A quote with no closing quote on its own line is not a string. JSX
    // text does this (<p>Don't</p>), and treating it as a string would
    // swallow code up to the next apostrophe in the file.
    if (c === '"' || c === "'") {
      let k = i + 1;
      let s = '';
      let closed = false;
      while (k < n && src[k] !== '\n') {
        if (src[k] === '\\') { s += src.substr(k, 2); k += 2; continue; }
        if (src[k] === c) { closed = true; break; }
        s += src[k]; k++;
      }
      if (closed) { push('str', s); i = k + 1; } else { push('p', c); i++; }
      continue;
    }
    if (c === '`') { i++; template(); continue; }

    if (c === '/' && regexOk()) {
      let k = i + 1;
      let inClass = false;
      let closed = false;
      while (k < n && src[k] !== '\n') {
        const e = src[k];
        if (e === '\\') { k += 2; continue; }
        if (e === '[') inClass = true;
        else if (e === ']') inClass = false;
        else if (e === '/' && !inClass) { closed = true; break; }
        k++;
      }
      if (closed) {
        k++;
        while (k < n && /[a-z]/.test(src[k])) k++;
        push('re', src.slice(i, k)); i = k; continue;
      }
    }

    if (ID_START.test(c)) {
      let k = i + 1;
      while (k < n && ID_PART.test(src[k])) k++;
      push('id', src.slice(i, k)); i = k; continue;
    }
    if ((c >= '0' && c <= '9') || (c === '.' && d >= '0' && d <= '9')) {
      let k = i + 1;
      while (k < n && NUM_PART.test(src[k])) k++;
      push('num', src.slice(i, k)); i = k; continue;
    }

    if (c === '(' || c === '[' || c === '{') { open.push(c); push('p', c); i++; continue; }
    if (c === ')' || c === ']') {
      if (open.pop() !== (c === ')' ? '(' : '[')) unsure = true;
      push('p', c); i++; continue;
    }
    if (c === '}') {
      const o = open.pop();
      push('p', '}'); i++;
      if (o === '${') { template(); continue; }
      if (o !== '{') unsure = true;
      continue;
    }

    // Shifts (<<, >>) stay single characters on purpose: the closing
    // `>>` of `Map<string, Array<number>>` has to count as two.
    const three = src.substr(i, 3);
    if (P3.has(three)) { push('p', three); i += 3; continue; }
    const two = src.substr(i, 2);
    if (P2.has(two)) { push('p', two); i += 2; continue; }
    push('p', c); i++;
  }
  if (open.length) unsure = true;
  return { toks, unsure };
}

// Index of the bracket that closes the one at `start`, or -1.
export function matchClose(toks, start) {
  const o = toks[start] && toks[start].v;
  const pairs = { '(': ')', '[': ']', '{': '}', '${': '}' };
  if (!pairs[o]) return -1;
  let depth = 0;
  for (let k = start; k < toks.length; k++) {
    const t = toks[k];
    if (t.t !== 'p') continue;
    if (t.v === '(' || t.v === '[' || t.v === '{' || t.v === '${') depth++;
    else if (t.v === ')' || t.v === ']' || t.v === '}') {
      depth--;
      if (depth === 0) return k;
    }
  }
  return -1;
}
