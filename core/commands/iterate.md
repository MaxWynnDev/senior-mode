---
description: Run a disciplined verification loop, fix, re-run the check, repeat until green or the cap hits. Never weakens the check to pass it.
argument-hint: <check command or remote job> [max-iterations=4]
---

Run a verification loop against a single check (the "oracle").
Doctrine: PROMPT-STANDARD.md, "Verification loops". The loop exists to
turn plausible code into verified code; it is worthless if the oracle
gets weakened along the way, so the integrity rules below override
everything including finishing.

## Setup

1. Oracle = the first argument in $ARGUMENTS. If none was given, pick
   the narrowest relevant check for the work just discussed and SAY
   which you picked before starting:
   - a single failing test file (narrowest test invocation available)
   - the unit suite
   - the typechecker
   - the e2e suite (only when the change is flow-level and a cheaper
     oracle cannot see it)
   In the remote-heavy verification model (WORKFLOW.md), the oracle is
   a CI workflow or job for the pushed SHA, never a local command: map
   `unit`/`test`, `typecheck`, `e2e` to the matching job. If no remote
   job exists for the check, stop with `REMOTE ORACLE UNAVAILABLE` and
   name the missing capability.
2. Cap = the second argument if present, else 4 iterations. Paid
   oracles (real-API evals) default to 2.
3. Run the oracle once BEFORE changing anything. If it is already
   green, say so and stop. Never "fix" what the oracle cannot see as
   broken. Say what RED looks like for this oracle (which output, which
   exit code, which `conclusion` field) so a vacuous green cannot pass
   as evidence.

## The loop

Repeat until green or the cap hits:

1. Read the failure output in full. Do not pattern-match on the first
   line; the real cause is often the second error.
2. Diagnose the root cause and state it in one line.
3. Apply the smallest fix consistent with that cause. No drive-by
   refactors inside the loop.
4. Re-run the oracle. Record the iteration: what changed (file:line),
   what the oracle said.

Speed rule: you may narrow to one test file while iterating, but the
FULL agreed check must run green once at the end or the loop did not
finish.

Flake rule: identical failure twice = real. A different failure each
run with no code change = suspect flake; rerun once to confirm before
chasing it.

Remote rule: never pipe a CI watcher through `tail`/`head`/`grep` (the
pipe's exit code replaces the run's). Redirect to a file and read the
run's `conclusion`; `success` is green, `cancelled`/`skipped`/null are
not.

## Oracle integrity (non-negotiable)

- Never delete, skip, `.todo`, or comment out a failing test.
- Never loosen an assertion, widen a type, lower a threshold, or relax
  a schema so the check passes.
- Never substitute a weaker check for the agreed one mid-loop.
- If you conclude the TEST is wrong (asserts behavior the spec
  contradicts), STOP the loop and report that with evidence
  (file:line, the conflicting spec or ADR). Changing the oracle is the
  human's call.

## Stop conditions

- GREEN: the full agreed check passes. Report and stop.
- CAP: iterations exhausted. Stop. Do NOT silently keep going.
- ORACLE-DISPUTE: you believe the check itself is wrong. Stop.
- REMOTE ORACLE UNAVAILABLE: the needed check has no remote job.
- STUCK: same failure signature twice with no progress. Stop and
  rethink the diagnosis; iterating harder on a wrong diagnosis burns
  tokens without converging.

## Report (end of loop, any exit)

```
# /iterate report

Oracle: <command or job>
Result: GREEN | CAP HIT | ORACLE-DISPUTE | REMOTE ORACLE UNAVAILABLE | STUCK
Iterations: <n>/<cap>
| # | change (file:line) | oracle said |
|---|---|---|

<if not GREEN: ranked hypotheses + the next thing to try>
Residual risk: <one line: what the oracle does NOT cover>
```

The "residual risk" line is mandatory: a green oracle proves what the
oracle checks, nothing more. High-stakes changes (money, tenancy,
migrations) still go through `/pre-push` and the matching specialist
agent regardless of loop outcome.
