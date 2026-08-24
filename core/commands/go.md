---
description: Finish the change in flight properly, verify it end to end, simplify it, then commit. The inner-loop closer.
argument-hint: [what to finish | blank = the current working-tree change]
---

GOAL: take the change in flight to done-done: verified against real
behavior, simplified, reviewed, committed. `$ARGUMENTS` names the change
when the working tree holds more than one thing; empty means "the
current change".

This is a composite: it chains the kit's existing pieces in the order
that catches the most problems for the fewest tokens. Run the steps in
order; do not skip a step because the previous one "looked fine".

WORKFLOW.md "Two verification models" decides WHERE step 1 runs. In the
local-heavy model (default) you run checks here. In the remote-heavy
model (CI owns every heavy check) you add or repair the tests as code,
do not execute them locally, and report runtime verification as
"pending the remote run for the pushed SHA".

## Step 1: VERIFY (behavior, not vibes)

Give the change a real feedback loop before any polish:

1. Run the narrowest deterministic check that covers the change (its
   unit tests, or the typecheck for type-level work). If new behavior
   has no test, write the failing test FIRST, confirm it fails for the
   right reason, then make it pass (PROMPT-STANDARD.md "Verification
   loops"). Use `/iterate <check>` when the fixing gets mechanical.
   Confirm the runner actually picks the test up: a committed test no
   runner imports never runs.
2. If the change has a runtime surface (page, route, CLI, job), drive
   it for real: launch the `app-verifier` agent with the flows this
   change touches, or exercise it yourself (dev server, curl, browser).
   Static green plus an undriven runtime path is NOT verified.
3. Run the full project check (lint/typecheck + unit suite) once at the
   end of this step. Read counts, not just the exit code.

## Step 2: SIMPLIFY (only what changed)

Run the code-simplifier pass over the changed files only (the
`code-simplifier` plugin agent or the bundled `/simplify`, or by hand:
dead branches, needless abstraction, duplication introduced by the
change). Apply the safe simplifications, then re-run the step-1 check.
A simplification that breaks the check is reverted, not negotiated
with.

## Step 3: REVIEW

Run `/review` on the final diff. Fix real findings; re-verify if the
fix touched behavior. If the diff hits a specialist surface (money,
tenant isolation, migrations, LLM call sites), run the matching
review agent from `.senior-mode/reviewers/` too.

## Step 4: COMMIT

Commit with a message that says what changed and why, ending with the
`Senior-Checklist:` trailer (the push gate requires it on HEAD).

CONSTRAINT: do NOT push. Pushing is the deploy flow's job (`/ship`
where wired, or the user's explicit call). Never weaken a check to get
through step 1; that rule is absolute.

STOP CONDITION: the change is committed, every check from step 1 is
green on the final tree (or explicitly pending remote CI), and you have
reported: what was verified (and how), what was simplified, review
verdict, commit SHA.
