---
description: Report files breaching the 400 LOC budget from ENGINEERING-PRINCIPLES section 12a
---

Enforce the section 12a lines-of-code budget. Read
`ENGINEERING-PRINCIPLES.md` section 12a before reporting so the exception
rule is correctly applied.

1. List every tracked source file over 400 LOC. A portable invocation
   (adapt the globs to your source layout and languages):

   ```bash
   git ls-files "*.ts" "*.tsx" "*.js" "*.py" "*.go" "*.rs" "*.java" "*.kt" "*.rb" "*.cs" \
     | xargs wc -l | sort -rn | awk '$1 > 400'
   ```

   `git ls-files` already excludes ignored dirs (node_modules, build
   output). Generated files and migrations are exempt by category.

   Note: on Windows prefer `wc -l` via the bash tool; PowerShell's
   `Measure-Object -Line` undercounts by the blank-line count.

2. For each over-budget file, grep the first 20 lines for the exception
   comment `PRINCIPLES: max-lines-exception` (any reason text after it
   counts as a declared exception).

3. Group the output:
   - **DECLARED OVERAGE**: over 400 with a valid exception comment.
     Print file, LOC, and the reason text.
   - **UNDECLARED OVERAGE**: over 400 with NO exception comment. Debt.
     Print file and LOC, sorted descending. These must get a split or an
     explicit exception declaration.
   - **AT RISK**: between 350 and 400. One feature away from breaching.

4. For the top 3 UNDECLARED files (capped to keep the audit inside one
   context window), read each and propose a split: name 2 to 4 logical
   slices that could become separate modules.

Output as a markdown report. End with a one-line verdict:
`<N> undeclared, <N> declared, <N> at risk`.

Do not modify any files.
