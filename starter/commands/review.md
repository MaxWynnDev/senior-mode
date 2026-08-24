---
description: Quick single-reviewer pass over the current diff (bugs, safety, quality). Informational only.
---

GOAL: one fast review pass over the current diff. Informational; it
does not block any action.

## Step 1: find the diff

Use the first that is non-empty:

1. `git diff @{upstream}...HEAD` (committed changes ahead of the remote)
2. `git diff --staged`
3. `git diff HEAD~1 HEAD`

If all are empty, print `no diff to review` and stop. If the diff is
over ~200KB, say so and review only the most material files.

## Step 2: review

Read `~/.claude/ENGINEERING-PRINCIPLES.md` (sections 3, 4, 12, and 19)
if it is not already in context, then check the diff for:

1. **Obvious bugs**: off-by-one, missing null checks at boundaries,
   raw user input in SQL or shell, a GET handler that writes, UI that
   treats "not loaded yet" as "empty", a changed value shape whose
   readers were not all updated.
2. **Access control**: an ID taken from the request body instead of
   the session, a missing ownership check before get/update/delete,
   secrets compared with string equality.
3. **Money and data paths**: floats for money, a multi-table write
   outside a transaction, a silent state change with no audit trail.
4. **Quality**: half-finished implementations, premature abstraction,
   `console.log`/print debugging left in prod paths, TODO without an
   owner and date, a new test file no runner imports, a file that
   grew past ~400 lines without a reason.
5. **Verification honesty**: does the change claim a green check that
   could not have gone red?

Report findings as a markdown bullet list grouped by severity
(HIGH / MEDIUM / LOW), each with the concrete failure scenario and
`file:line`. Skip empty categories. End with a one-line verdict:
CLEAN / MINOR / NEEDS REVIEW / BLOCKER.

If the diff is trivial (docs, formatting, comments), output "no
concerns" and stop.

Any HIGH finding gets fixed, or explicitly rebutted with evidence,
before pushing.
