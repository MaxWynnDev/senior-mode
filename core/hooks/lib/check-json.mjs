// Is each .json file still JSON after the edit?
//
//   node check-json.mjs <file>...
//
// A file with comments or trailing commas passes: plenty of config files
// that end in .json are read that way by their tools. A file that is
// broken even with those allowed gets one line, `<path>:1: invalid JSON:
// <parser message>`, and exit 1. Any failure of this script prints
// nothing and exits 0.

import fs from 'node:fs';
import { readJsonLoose } from './js-resolve.mjs';

let bad = 0;
try {
  for (const file of process.argv.slice(2)) {
    let text;
    try { text = fs.readFileSync(file, 'utf8'); } catch { continue; }
    if (!text.trim()) continue;
    try { JSON.parse(text); continue; } catch (err) {
      if (readJsonLoose(file) !== null) continue;
      process.stdout.write(`${file.replace(/\\/g, '/')}:1: invalid JSON: ${String(err.message).replace(/\s+/g, ' ')}\n`);
      bad = 1;
    }
  }
} catch { bad = 0; }
process.exit(bad);
