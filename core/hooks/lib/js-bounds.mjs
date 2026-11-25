// Two index shapes that are wrong whatever the code around them means,
// read from a token list from js-lex.mjs. Split from js-facts.mjs to keep
// both files inside the 400-line budget.

import { matchClose } from './js-lex.mjs';

const isP = (t, v) => !!t && t.t === 'p' && t.v === v;
const isId = (t, v) => !!t && t.t === 'id' && (v === undefined || t.v === v);
const ASSIGN = new Set(['=', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '**=', '&&=', '||=', '??=']);

// The `a.b.c` chain that ends just before token i, as its token values.
function chainBefore(toks, i) {
  const out = [];
  let k = i - 1;
  if (!isId(toks[k])) return out;
  out.unshift(toks[k].v); k--;
  while (k >= 1 && isP(toks[k], '.') && isId(toks[k - 1])) { out.unshift('.'); out.unshift(toks[k - 1].v); k -= 2; }
  const left = toks[k];
  if (left && left.t === 'p' && (left.v === '.' || left.v === '?.' || left.v === ')' || left.v === ']')) return [];
  return out;
}

// Two index shapes that read one past the end no matter what the code
// around them means: arr[arr.length], and a loop bounded by
// `i <= arr.length` whose body reads arr[i].
export function boundsOf(toks) {
  const out = [];
  for (let i = 0; i < toks.length; i++) {
    const t = toks[i];
    if (isP(t, '[')) {
      const chain = chainBefore(toks, i);
      if (!chain.length) continue;
      let k = i + 1;
      let same = true;
      for (const v of chain) {
        if (!toks[k] || toks[k].t === 'str' || toks[k].v !== v) { same = false; break; }
        k++;
      }
      if (!same || !isP(toks[k], '.') || !isId(toks[k + 1], 'length') || !isP(toks[k + 2], ']')) continue;
      const after = toks[k + 3];
      if (after && after.t === 'p' && ASSIGN.has(after.v)) continue;
      const a = chain.join('');
      out.push({ line: t.line, msg: `${a}[${a}.length] reads one past the last element, so it is always undefined. The last element is ${a}[${a}.length - 1].` });
    } else if (isId(t, 'for') && isP(toks[i + 1], '(')) {
      const close = matchClose(toks, i + 1);
      if (close < 0) continue;
      for (let k = i + 3; k < close - 3; k++) {
        if (!isP(toks[k], '<=') || !isId(toks[k - 1])) continue;
        const idx = toks[k - 1].v;
        const chain = [];
        let j = k + 1;
        while (j < close && (isId(toks[j]) || isP(toks[j], '.'))) { chain.push(toks[j].v); j++; }
        if (chain.length < 3 || chain[chain.length - 1] !== 'length' || chain[chain.length - 2] !== '.' || !isP(toks[j], ';')) continue;
        const arr = chain.slice(0, -2).join('');
        let end = close + 1;
        if (isP(toks[end], '{')) end = matchClose(toks, end);
        else while (end < toks.length && !isP(toks[end], ';')) end++;
        if (end < 0) continue;
        for (let b = close + 1; b < end; b++) {
          if (!isP(toks[b], '[') || !isId(toks[b + 1], idx) || !isP(toks[b + 2], ']')) continue;
          if (chainBefore(toks, b).join('') !== arr) continue;
          out.push({ line: t.line, msg: `the loop runs while ${idx} <= ${arr}.length and reads ${arr}[${idx}], which is undefined on the last pass. Use ${idx} < ${arr}.length.` });
          break;
        }
        break;
      }
    }
  }
  return out;
}
