# Development & Deployment Workflow

The source of truth for how code reaches production. Read it before
changing CI or running a migration. If anything here is wrong, fix the
doc in the same commit as the behavior change.

<!-- SETUP: this file is a stack-neutral template. It ships with one
opinionated default (push to the mainline behind a CI deploy gate,
manual migrations) and names the alternatives where they exist. Keep ONE
model per decision and delete the others so the doc never disagrees with
itself. The reference stack profile (stacks/nextjs-vercel-postgres/
WORKFLOW.md) is a fully concrete version of this file for Next.js +
Postgres + Vercel; if you installed that profile, it replaced this one. -->

## TL;DR (default model; adapt to yours)

```
local edit
     │
     ├─ pre-commit hook          LOC / print-debug / TODO gate (kit)
     ├─ pre-push hook            Senior-Checklist trailer gate (kit)
     ▼
git push <mainline>
     │
     ├─ preview deploy           instant, per branch (if your platform has it)
     ├─ CI                       typecheck + unit + integration + e2e (+ AI eval gate)
     │      │ conclusion: success
     │      ▼
     └─ production deploy        gated on CI green, then a rolling release
```

DB migrations are intentionally OUTSIDE this loop. See
[Migrations](#migrations).

## Branching model

Pick one and delete the other:

- **Push to the mainline (default).** No pull requests, no branch
  protection. Safety lives in the ship loop in front (audit, commit
  gate), CI, the deploy gate, and rollback. Parallel sessions isolate in
  worktrees and land on the mainline by rebase + push.
- **Pull requests with a protected branch.** Each change is a short
  branch and a PR; CI runs on the PR; merge deploys. `/worktree` still
  applies (one worktree per PR); `/ship` ends at "PR opened and green"
  rather than "pushed to the mainline".

## Two verification models

Decide where heavy verification (installs, dev servers, typecheck, test
suites, e2e, evals, builds) runs, and say so in CLAUDE.md, because `/go`,
`/iterate`, and the app-verifier behave differently under each:

| | Local-heavy (default) | Remote-heavy |
|---|---|---|
| Typecheck / unit / e2e | run locally before push, again in CI | CI only; the pushed SHA is the first execution |
| `/go` step 1 | runs the checks and the app-verifier here | adds tests as code; verification is "pending remote" |
| `/iterate` oracle | a local command | a CI job for the SHA |
| app-verifier | boots the app locally | watches the remote run / inspects a deployed target |
| Good for | fast inner loops, laptops with the toolchain | shared or weak machines, strict "CI is the oracle" teams |

Remote-heavy teams may want a PreToolUse guard that denies heavy local
commands in agent sessions; that is a project decision, not a kit
default, and the kit's hooks do not impose it.

## What runs where (default model)

| Stage            | Where                     | What                          |
| ---------------- | ------------------------- | ----------------------------- |
| Pre-commit       | Local machine (kit hook)  | LOC budget, print-debug, TODO |
| Pre-push         | Local machine (kit hook)  | Senior-Checklist trailer      |
| Preview deploy   | Platform, automatic       | build against a branch DB     |
| CI               | CI provider, on push      | typecheck + unit + integration + e2e |
| Prod deploy gate | Platform deploy gate      | checks CI status              |
| Prod deploy      | Platform, when gate passes| build, then rolling release   |
| Migrations       | Local terminal, manual    | the sanctioned runner         |
| Error monitoring | Your error reporter       | server + client SDK, release = git SHA |

## Local dev

```bash
<install deps>
<pull env vars>      # one-time per machine
<dev command>        # boots the app
```

Use a dev/branch database, never prod. If your env file holds a
production connection string for scripts, keep the dev server on a
separate env file that Next/your framework loads first, so `dev` hits a
branch while operational scripts still see prod on purpose.

## Pushing changes

```bash
git add <paths>          # explicit paths, not -A, when peers share the checkout
git commit -m "what changed and why

Senior-Checklist: ambiguity=pass summary=pass concurrency=n/a regression=pass blast=green"
git push origin <mainline>
```

The pre-push hook rejects a push without the trailer. CI re-runs the
checks; the deploy gate holds the production build until CI's
`conclusion` is `success` (`cancelled`, when a later push superseded
yours, is not green: prove your SHA is an ancestor of the deployed one).

## The ship loop (default for behavior-changing updates)

```
audit (/review, /pre-push where the diff warrants it)
   -> commit with the Senior-Checklist trailer
   -> [optional] stage on demand + sweep + fix, max 3 iterations
   -> push the exact SHA
   -> watch CI to a green conclusion (fix forward, max 3 iterations)
   -> confirm the deploy for that SHA reached ready
   -> [unless light] post-deploy checks on the live target
```

`/ship` runs it. Exceptions that push directly: docs/comments-only,
emergency rollbacks, explicit "quick push". Money-path and migration
diffs always take the full loop plus `/pre-push`. Wire
`.senior-mode/hooks/ship-policy.sh` into `UserPromptSubmit` to keep the
policy in front of every prompt.

## Parallel sessions (git worktrees)

Multiple Claude Code sessions in one checkout tangle the working tree:
edits and commits from different sessions mix, and recovery usually
costs a hard reset. The kit automates the discipline:

- Every session registers a heartbeat at `SessionStart`
  (`.senior-mode/hooks/session-registry.sh`) and unregisters at `SessionEnd`;
  each one is told who else is live, where, on what branch. A session
  whose HEAD shares no ancestor with the mainline gets a lineage alert
  before it can push over the remote's history.
- The earliest session in a checkout (the incumbent) works normally.
  Later sessions in the same checkout are steered to `/worktree`, and
  `.senior-mode/hooks/session-tree-guard.sh` blocks their commit/push until
  they isolate (`CLAUDE_ALLOW_SHARED_GIT=1` overrides one command when
  a flagged peer is actually dead).
- Worktrees are git-isolation only unless you install deps there. Ship
  by rebasing onto the mainline and pushing `HEAD`. `/worktree done`
  cleans up; leave the worktree directory before removing it.

## Staging on demand (optional)

No standing staging environment. When a change is scary enough that CI
plus a preview build is not enough confidence, stage it on demand: a
copy-on-write branch of the production database plus a preview deploy
wired to it, torn down after the sweep. The reference stack profile
ships scripts for this (`stage:up` / `stage:down`); on another stack,
the shape is the same: branch the data, deploy the tree against it,
alias it, smoke it, delete it.

`--migrate` is the headline: rehearse a migration against a
byte-identical copy of prod before the real prod migration runs.

## QA sweeps (optional)

A synthetic-data QA sandbox tenant lets agents exercise deployed
targets with real integrations and zero customer risk. A sweep brief
(the reference profile's `QA-SWEEP.md`) pairs a deterministic
render-every-page spec (also in gating CI) with an agent-driven
exploratory pass. Never sweep during a rolling release: version skew
produces false-positive hydration errors. Agents scout; deterministic
specs gate.

## Migrations

**Migrations never run automatically.** They are not in the build
command. Reasons:

- A migration that succeeds during a build can still leave a
  half-shipped schema if the deploy fails afterwards.
- A bad migration on a shared multi-tenant DB affects every customer at
  once. It needs human supervision.

To apply pending migrations to prod, use the one sanctioned runner,
which should:

1. Verify the target looks like a prod host, and (if the app runs as a
   restricted role) that the owner URL targets the SAME database.
2. Verify HEAD descends from the mainline, so a stale worktree cannot
   invoke an older runner.
3. Print the migrations about to be applied, with their hashes.
4. Demand an explicit typed confirmation before running.
5. Take a database-level advisory lock so two runners cannot interleave,
   and apply DDL plus the tracking rows in one transaction.

**Always migrate BEFORE** the deploy that depends on the schema, not
after. Keep migrations additive so a deploy works against either schema;
destructive drops happen in a follow-up deploy after the code stops
referencing the column.

If a migration fails partway, **stop**. A transactional runner has
rolled back; inspect the error and the exact schema state before
choosing fix-forward or a point-in-time restore. A blind restore
discards unrelated writes made after the snapshot.

## On-call basics

When prod breaks:

1. Roll back to the previous good deploy. It is the fast lever; a
   30-second rollback beats a 30-minute hot-fix. Exception: during a
   documented fix-forward migration window, preserve the database and
   ship a verified fix instead.
2. Check the error reporter for the trace.
3. Check the DB/infra dashboard for slow or failing queries.
4. If a migration is the cause: restore the snapshot to a fresh branch,
   verify, swap; revert the migration commit; redeploy.

## Things this workflow deliberately does NOT have

<!-- List what you have consciously skipped so a future session does not
add it back. Delete if not applicable. Example entries: pull requests /
branch protection, a separate staging environment, feature flags,
auto-migration on deploy. -->

- <...>
