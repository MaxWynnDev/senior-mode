---
description: Probe the boundaries a diff added. Flip each comparison and each +1 or -1, run the tests, and report the ones no test notices.
argument-hint: [--base <ref>] [--test "<command>"] [file...]
---

GOAL: find the off by one that every other check passes. Arguments:
`$ARGUMENTS` (none probes the uncommitted work against HEAD).

No check that reads code can tell `<` from `<=`. Both parse, both
typecheck, both look right. The line is only wrong against what the code
is for, and the one thing that knows that is a test at the edge. This
procedure asks each test suite a direct question: if the boundary moved
by one, would you notice?

## Run it

```
bash .senior-mode/hooks/boundary-probe.sh $ARGUMENTS
```

- It reads the lines the diff added and takes every ` < `, ` <= `,
  ` > `, ` >= `, ` + 1` and ` - 1` on them (test files, comments and
  strings are skipped).
- It runs the unchanged tree first. A red baseline stops it: a flip on a
  red suite proves nothing.
- It flips one boundary, runs the tests, puts the file back, and moves
  to the next. `KILLED` means the tests went red. `SURVIVED` means they
  stayed green with the boundary moved.
- The test command comes from `--test`, then
  `SENIOR_MODE_TEST_RELATED_CMD`, then `commands.test_related` or
  `commands.test` in the stack profile. `{file}` in the command is
  replaced with the probed file, so a runner that takes a path runs
  only what covers it.

It edits the file in place for the length of one test run. If another
session shares this checkout, run it from your own worktree (the
`worktree` procedure). If the project's tests only run in CI, run the
probe there too, as a job on the push's diff.

## Read the result

- All `KILLED`: every boundary you added is pinned. Say so, with the
  count.
- A `SURVIVED` line: write the test at that edge before anything else.
  The empty case, exactly at the limit, one past it. Then run the probe
  again and show the flip is killed. Do not adjust the boundary to make
  the probe quiet, and do not call the survivor "equivalent" without
  showing the two versions return the same thing for every input.
- Every flip survived: the test command probably runs nothing that
  imports the file. Check that before you write a single test.

STOP CONDITION: the probe exits 0, or each survivor has a new test and a
second run that kills it. Report the flips, what each new test asserts,
and the exit code of the last run.
