---
description: Pull recent commits, error-reporter activity, and deploy state for triage
argument-hint: [symptom or error text]
---

GOAL: triage a possible production incident fast. Correlate what
changed (commits, deploys) with what is breaking (error reporter,
symptom in $ARGUMENTS if given) and recommend the next action.

CONSTRAINT: read-only. Do not revert, redeploy, or edit anything in
this command; recommend, and let the user decide. Speed matters more
than completeness: a 2-minute triage that names the suspect commit
beats a 20-minute exhaustive sweep. Never cite a run, log, or error you
did not open in this session.

## Procedure

Adapt each step's command to the project's platform (WORKFLOW.md names
the tools). The reference stack's invocation is shown in brackets.

1. **What changed.** `git log --oneline -10` on the mainline. Note
   anything touching money paths, auth, middleware, or migrations.
2. **Deploy state.** List the latest production deploys with status
   and age [reference stack: `vercel ls --prod | head -8`]. If the
   pipeline has a CI-gated deploy, a canceled build seconds old is the
   gate working, not a failure. Flag: an errored build, a Ready deploy
   much older than the latest mainline commit (change not live yet),
   or a deploy mid-rollout right now.
3. **CI state.** `gh run list --limit 3` (or your CI's equivalent). A
   red run explains a missing deploy. Read the `conclusion` field, not
   a watcher's exit code.
4. **Error reporter.** If a token is available in the environment, list
   the newest unresolved issues with event counts and release tags
   (each release tag should be a git SHA: the deploy the error entered
   on). If the token is missing, say so in one line and continue. Never
   pull secrets to local files from an agent session.
5. **Scheduled jobs.** If the symptom smells scheduled (stuck queue,
   missing reconciliation, dead outbox), check the cron run log the
   project keeps. A cron silent for days is a classic silent outage.
6. **Correlate.** Match error release SHAs against the commit list.
   On a hit, `git show --stat <sha>` and read the diff of the suspect
   commit.

OUTPUT SHAPE: a short markdown report: `## Timeline` (what shipped
when), `## Errors` (what the reporter says, or "reporter unavailable"),
`## Correlation` (which commit maps to which error, or "none found"),
`## Recommendation` (one of: revert <sha>, fix forward <specific fix>,
keep watching <what signal>, no incident). Lead with the
recommendation if the evidence is strong.

STOP CONDITION: recommendation printed. If the user says "do it", the
fix or revert then follows normal rules (an emergency rollback is an
allowed direct push under the ship policy; a platform rollback is the
fastest lever when the deploy correlates).
