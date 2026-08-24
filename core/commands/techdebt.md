---
description: Session-end sweep for tech debt, duplication, dead code, doc drift, aging TODOs. Read-only; ranked report.
argument-hint: [path or scope | blank = recent work]
---

GOAL: find the debt this recent work added or exposed, while the
context is still warm. Run at the end of a working session, before the
knowledge of "what we just touched" evaporates.

EVIDENCE: scope is `$ARGUMENTS` when given (a path or module). When
blank, derive it from recent work: `git diff origin/<mainline>...HEAD
--name-only`, plus `git log --oneline -10 --name-only` for the files
touched by the last few commits, plus the current working tree.

Look for, in priority order:

1. **Duplication.** Logic the recent work copied instead of extracting,
   or a new near-twin of an existing helper. Grep for distinctive
   fragments of the new code across the repo. When a commit claims it
   centralized a value "declared N times", grep the VALUE and its
   spellings (SQL literals included); the count is a claim, not
   evidence.
2. **Dead code.** Exports, branches, flags, or files the recent change
   orphaned (the old code path after a replacement shipped).
3. **Doc drift.** CLAUDE.md, WORKFLOW.md, `.senior-mode/rules/*`, ADRs, or
   comments that the change just made wrong (a renamed command, a moved
   file, a changed default).
4. **Aging TODOs.** TODO/FIXME in or near the touched files: anything
   without an owner and date, or whose date has quietly passed.
5. **Budget pressure.** Files the work pushed toward or over the LOC
   budget (`/loc-budget` covers the repo-wide view; here flag only what
   this session grew).
6. **Unwired safety.** A test, guard, or check the session added that
   nothing runs (not imported by the runner, not wired in CI, not in
   settings.json). It reads as coverage and is not.

CONSTRAINT: read-only. No edits, however tempting. Precision over
volume: a false positive costs a review slot; cite file:line evidence
for every item or drop it.

OUTPUT SHAPE: a ranked markdown list (worst first), each item with
file:line, one-line description, and the suggested action (extract /
delete / update doc / split / wire). End by offering exactly two
follow-ups: fix the top N now, or record the list (memory, a DEBT.md,
or the tracker CLAUDE.md names).

STOP CONDITION: report delivered. Do not start fixing unless the user
picks that follow-up.
