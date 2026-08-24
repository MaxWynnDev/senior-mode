---
description: The verified ship loop - audit, commit, push, watch CI to a green conclusion, watch the deploy, run post-deploy checks, fix forward until clean
argument-hint: [light]
---

GOAL: ship the current change through the project's verified loop
(WORKFLOW.md is the source of truth for the pipeline shape). Adopt this
as the DEFAULT path for behavior-changing updates if the project has
opted in (CLAUDE.md "Deploy flow" plus the optional `ship-policy.sh`
hook). Argument: `$ARGUMENTS` (`light` = skip the optional post-deploy
QA leg; never skips gating CI).

Exceptions that push directly instead: docs/comments-only diffs,
emergency rollbacks, or the user explicitly saying "quick push".
Money-path or migration diffs are NEVER light: full loop plus
`/pre-push` reviewer fan-out.

## The loop

1. **Pre-flight.** `git status --short`, the complete diff, and the
   latest mainline CI state. Confirm the diff is what you intend to
   ship and contains no other session's files. Do not push on top of an
   unexplained red predecessor.
2. **Audit.** `/review` plus the relevant read-only specialists
   (`/pre-push` when the diff hits money, tenancy, PII, auth, security,
   or migrations). Fix real findings. In the local-heavy verification
   model, run the typecheck and unit suite here; in the remote-heavy
   model, CI is the first execution oracle.
3. **Stage (optional).** If the project has staging on demand
   (`stage:up` from the reference stack's QA pack, or your equivalent),
   deploy the working tree there and run the sweep brief against it.
   Fix critical/high findings, re-stage, re-sweep; maximum 3
   iterations, then STOP and present remaining findings rather than
   shipping or weakening the check. Skip this step if the project has
   no staging leg.
4. **Commit.** The exact intended files, with the `Senior-Checklist:`
   trailer. Record the SHA.
5. **Push.** To the deploy branch (or open the PR, if the project uses
   them). The lightweight pre-push guards still run; do not use
   `--no-verify` without the user's explicit authorization.
6. **Watch CI.** Find the run for the exact SHA and watch it to
   completion. Never pipe the watcher; redirect to a file and read the
   run's `conclusion`: `success` is green, `cancelled` (a later push
   superseded yours) and `skipped` are not. If red: read the full
   failing log, make the smallest correct fix, audit the new diff,
   commit, push again. Maximum 3 fix-forward iterations. Never weaken a
   check.
7. **Watch the deploy.** Confirm the production deploy for that SHA
   reached its ready state. Green CI is not "deployed"; a deploy that
   never fired, or one pinned to an older SHA, is a finding.
8. **Post-deploy QA** (unless `light`). Wait for any rolling release to
   finish, then run the project's deployed-target checks (the QA sweep
   workflow, a smoke script, or the app-verifier against the deployed
   URL). Fix forward through the same path if it finds a real
   regression.
9. **Clean up and report.** Tear down staging if you created it. Report:
   shipped SHA, CI run URL and conclusion, deploy state, QA result when
   run, fixes made during the loop, deferred findings, residual risk.

## Stop conditions

- SHIPPED: exact SHA is on the deploy branch, CI conclusion is
  `success`, the deploy is ready, and any requested post-deploy QA is
  clean.
- CI RED: 3 fix-forward iterations exhausted. Report the run and the
  remaining failure.
- DEPLOY BLOCKED: CI is green but the deploy is not ready. Report the
  deployment and gate logs.
- ABORTED: the user declines to ship after pre-flight or audit.
