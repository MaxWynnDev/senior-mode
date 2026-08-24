---
description: Review the current diff against PROMPTING.md and engineering principles
---

GOAL: one fast single-reviewer pass over the current diff. The light
sibling of `/pre-push` (which fans out the specialist agents); reach
for this when the diff is small or you want a quick second opinion.
Informational only; it does not block any action.

## Step 1: find the diff

Try in this order, use the first that is non-empty:

1. `git diff origin/<mainline>...HEAD` (committed changes ahead of the deploy branch)
2. `git diff --staged` (staged but uncommitted)
3. `git diff HEAD~1 HEAD` (last commit alone)

If all are empty, print `no diff to review` and stop. If the diff is
over ~200KB, say so and review only the most material files.

## Step 2: review against the rubric

Read `PROMPTING.md` and `ENGINEERING-PRINCIPLES.md` at the repo root,
then check the diff for:

1. **PROMPTING.md violations** (only on files that call the Anthropic
   SDK): hardcoded dates in cached system prompts, missing spend-budget
   gate, missing post-parse validation, user fragments concatenated
   without XML delimiters, missing retry block.
2. **ENGINEERING-PRINCIPLES violations**: new files over 400 LOC,
   missing tests on money-path code, premature abstraction, half-
   finished implementations, `console.log` in prod paths, TODO without
   owner/date, a test file no runner imports.
3. **Obvious bugs**: off-by-one, missing null checks at boundaries,
   access-control bypass (tenant ID from request body, missing access
   check), raw user input in SQL or shell, a GET handler that writes,
   UI that treats "not loaded yet" as "empty".
4. **Money-path safety**: anything touching payments/payouts/billing;
   silent state changes without an audit trail.
5. **User-facing copy**: brand-name casing, em/en dashes, corporate
   filler, copy that lists a sample of cases where it should state the
   rule.

Report findings as a markdown bullet list grouped by severity
(HIGH / MEDIUM / LOW), each with the concrete failure scenario and
file:line. Skip empty categories. End with a one-line verdict:
CLEAN / MINOR / NEEDS REVIEW / BLOCKER.

If the diff is trivial (docs, formatting, comments), output just
"no concerns" and stop.

Two hard rules on acting from this report:

- Any HIGH-severity finding gets addressed (or explicitly rebutted
  with evidence) before pushing.
- A finding on a money path or migration upgrades the next step to
  `/pre-push` so the specialist reviewers see it too.
