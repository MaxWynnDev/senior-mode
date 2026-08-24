# Development & Deployment Workflow (reference stack)

The source of truth for how code reaches production on the reference
stack: Next.js on Vercel, Postgres with branching (Neon), Drizzle
migrations, GitHub Actions CI. Read it before changing CI or running a
migration. If anything here is wrong, fix the doc in the same commit as
the behavior change.

<!-- SETUP: this is the concrete version of the core WORKFLOW.md. It
assumes push-to-mainline behind a CI deploy gate and the local-heavy
verification model. Switch either decision here and in CLAUDE.md. -->

## TL;DR

```
local edit
     │
     ├─ kit hooks                  LOC / print-debug / TODO gate, Senior-Checklist trailer
     ├─ pre-push (husky)           lightweight structural guards; typecheck + unit in the local-heavy model
     ▼
git push origin main
     │
     ├─ Vercel build #1            fires immediately; the deploy gate (ignoreCommand)
     │                             cancels it because CI is still in progress.
     │                             This is correct fail-closed behavior.
     ├─ GitHub Actions CI          typecheck + unit + integration (ephemeral Postgres)
     │                             + Playwright (incl. a phone viewport) + AI eval gate
     │      │ conclusion: success
     │      ▼
     ├─ deploy-on-ci-green.yml     creates a production deployment pinned to the
     │                             exact SHA that passed (or fires the deploy hook)
     │      │
     │      ▼
     └─ Vercel build #2            gate sees CI green, builds, then
        Rolling Release            10% -> 50% -> 100% over ~10 min, auto-rollback on error spike
```

Two builds per push is intentional: the first is a 4-second cancel that
proves the gate is fail-closed; the second is the real production
deploy. Nobody clicks anything.

DB migrations are intentionally OUTSIDE this loop. See
[Migrations](#migrations).

## What runs where

| Stage             | Where                              | What                                        |
| ----------------- | ---------------------------------- | ------------------------------------------- |
| Edit + commit     | Local machine (kit hooks)          | LOC / print-debug / TODO gate, trailer gate |
| Pre-push          | Local machine (husky)              | structural guards (+ typecheck + unit locally in the local-heavy model) |
| Preview deploy    | Vercel, automatic on push          | `next build` against a Postgres preview branch |
| CI                | GitHub Actions, on push to main    | typecheck + tests + Playwright + fingerprint-gated AI evals |
| Prod deploy gate  | Vercel `ignoreCommand`             | a script that checks the CI status for the SHA |
| Prod deploy       | GitHub Actions + Vercel            | exact-SHA deploy, gate, then Rolling Release |
| Production QA     | GitHub Actions, on demand/nightly  | page sweep against the live site with the QA sandbox login |
| Migrations        | Local terminal, manual             | `pnpm db:migrate:prod`                      |
| Error monitoring  | Sentry (or equivalent)             | server + edge + browser SDK; release = git SHA |

## Local dev

```bash
pnpm install
vercel env pull apps/web/.env.local      # one-time per machine
pnpm dev:db                              # one-time: an isolated Postgres branch for dev
pnpm dev                                 # boots web on the dev port
```

`vercel env pull` brings down the PRODUCTION environment, so `.env.local`
holds the prod `DATABASE_URL`. Keep the dev server on a separate,
gitignored `.env.development.local` that points at a `dev/local` branch
(a script that creates or reuses the branch and writes the file). Next
loads that file ahead of `.env.local` for `next dev` ONLY, which draws
the line exactly where it belongs: `pnpm dev` hits the branch;
operational scripts still see prod on purpose. A fail-closed guard in
the DB module refuses to connect a non-production `NODE_ENV` to the prod
endpoint.

Connect the dev server as the same restricted role prod uses once RLS is
on; the branch owner role bypasses RLS and would make a missing wrapper
invisible locally and a zero-rows bug in prod.

## Pushing changes

```bash
git add <paths>
git commit -m "what changed and why

Senior-Checklist: ambiguity=pass summary=pass concurrency=n/a regression=pass blast=green"
git push origin main
```

CI re-runs every check on Linux. The deploy gate holds the production
build until CI's `conclusion` is `success`. A `cancelled` run means a
later push superseded yours: your code ships with THEIR deploy only if
your SHA is an ancestor of the deployed one; prove it with
`git merge-base --is-ancestor <your-sha> <deployed-sha>`.

Watching CI from an agent session: never pipe the watcher.

```bash
gh run watch <id> --exit-status > watch.log 2>&1; echo "WATCH_EXIT=$?"
gh run view <id> --json status,conclusion
```

`deploy-on-ci-green.yml` should: verify the green SHA is still the
mainline tip (or an ancestor), refuse to regress a newer deployment,
serialize parallel pushes, and wait for the deployment to reach
`READY`/`PROMOTED`. A `PRODUCTION_DEPLOY_HOLD` marker file committed in a
green SHA lets the workflow complete WITHOUT deploying, as an interlock
for a migration rollout; the commit that satisfies the removal criteria
deletes it.

## The ship loop

`/ship` runs: audit, commit, push, watch CI to a green conclusion (fix
forward, max 3), confirm the deploy for the SHA reached Ready, then
(unless `light`) wait for the rolling release to finish and dispatch the
production QA sweep workflow. Behavior-changing updates take this path;
docs-only diffs, emergency rollbacks, and an explicit "quick push" do
not. Money-path and migration diffs always add `/pre-push`.

## Parallel sessions (git worktrees)

As in the core doc: the session registry banners on start, the tangle
guard blocks a non-incumbent's commit/push in a shared checkout,
`/worktree` isolates, and the lineage alert catches a stranded HEAD.
Worktrees have no `node_modules` by default; run dev and tests from the
main checkout, or `pnpm install` in the worktree once. Ship from a
worktree with `git fetch origin && git rebase origin/main` then
`git push origin HEAD:main`.

## Staging on demand

There is no standing staging environment (see the bottom of this doc
for why). When a change is scary enough that CI plus a preview build is
not enough confidence:

```bash
pnpm stage:up             # Postgres branch off prod + preview deploy + alias
pnpm stage:up --migrate   # also run pending migrations against the BRANCH
pnpm stage:down           # list stage/* branches (dry run)
pnpm stage:down --apply   # delete them
```

What `stage:up` does (`qa/stage-up.mjs`):

1. Creates a Postgres branch named `stage/<timestamp>-<sha>`: a
   copy-on-write snapshot of live prod data, isolated for writes.
2. Deploys the current working tree as a Vercel preview with
   `DATABASE_URL` pointed at the branch and `NEXT_PUBLIC_APP_URL` baked to
   the staging alias (so auth trusted origins line up).
3. Aliases it and smoke-checks `/api/health`.

Properties worth knowing:

- One-time setup: the branching API key in your env file. The script
  tells you this if it is missing.
- Crons never fire on preview deployments; whatever your Preview
  environment lacks (error reporting, OAuth secrets) is off by design.
- The staging URL sits behind Vercel SSO deployment protection. Open it
  in a browser where you are logged in, or set a protection bypass
  secret for the deterministic sweep.
- Live wires: OAuth tokens inside the branched data are REAL (a send
  from staging is a real send), and the blob store and rate-limit
  buckets are shared with prod. Never delete a document on staging.
- Branches cost storage; `stage:up` warns when 3 or more exist. If
  several sessions stage at once, use a per-worktree alias so one
  session cannot repoint another's target mid-sweep.

## QA sweeps

A synthetic-data QA sandbox tenant (seeded per
`qa/QA-SANDBOX-SEED-CHECKLIST.md`) lets agents exercise deployed
targets with real integrations and zero customer risk. `QA-SWEEP.md`
is the canonical brief: the deterministic page sweep
(`qa/pages-smoke.spec.template.ts`, also in gating CI) plus an
agent-driven exploratory pass. `/qa-sweep` runs it; the nightly
workflow (`qa/qa-sweep.yml.template`) sweeps production on a schedule.
Never sweep during a rolling release: version skew produces
false-positive hydration errors. Agents scout; deterministic specs gate.

## Migrations

**Migrations never run automatically.** Drizzle is not in the build
command and never will be. Reasons:

- A migration that succeeds during a build can still leave a
  half-shipped schema if the deploy fails afterwards.
- A bad migration on a multi-tenant DB affects every customer at once.
  It needs human supervision.

To apply pending migrations to prod:

```bash
git fetch origin
git merge-base --is-ancestor origin/main HEAD   # must exit 0
pnpm db:migrate:prod
```

The sanctioned runner should:

1. Prefer an owner connection for DDL, verify it targets the SAME
   database as the runtime URL, and verify the role owns the tables.
   Never replace the runtime `DATABASE_URL` with the owner credential.
2. Verify the URL looks like a prod host.
3. Print every pending journal entry with its timestamp and SQL hash,
   and reject non-advancing timestamps (a stale watermark from a
   parallel session is silently skipped otherwise).
4. Demand a literal typed `APPLY`.
5. Re-fetch and repeat the ancestry check after the human review
   window.
6. Take a transaction-scoped advisory lock so two runners cannot
   interleave; re-read the database and the files under the lock; stop
   if anything differs from what was approved.
7. Apply the SQL and the tracking rows in that same transaction.

**Always migrate BEFORE** the deploy that depends on the schema.
Additive in one deploy, destructive in a follow-up after the code stops
referencing the column. Rehearse with `pnpm stage:up --migrate` first.

If a migration fails, **stop**. The transactional runner rolled back;
inspect the error and the exact migration-table and schema state.
Point-in-time restore only for confirmed persisted corruption; a blind
restore discards unrelated writes made after the snapshot.

## Manual setup the platform needs

These live outside the repo. Do them once when standing up a new
environment.

### Vercel

1. Production env vars: the repo slug and a fine-grained token with
   `actions:read` for the deploy gate script (without it the gate fails
   closed and prod deploys are blocked); the error reporter DSN and
   auth token for source-map upload.
2. Rolling Releases: 10% for 5 min, 50% for 5 min, 100%; auto-rollback
   on error rate > 1%.
3. Storage integration: enable preview branching so each preview gets
   its own database branch.
4. Deployment Protection: keep SSO on previews; store a protection
   bypass secret for the deterministic sweep.

### Error reporter

1. Create the project (Next.js platform); copy the DSN to Vercel.
2. Create an internal integration token for source-map upload.
3. Alert rule: error rate > 1% for 5 min to your on-call channel.

### Postgres

1. Confirm point-in-time restore retention is at least 7 days.
2. Test a restore once before launch. A backup you've never restored
   is not a backup.

### GitHub

1. Repository secret with a Vercel token that can create deployments
   for the project (sent only to the Vercel API, never logged).
2. Optionally a deploy-hook URL as the missing-token fallback.
3. No branch protection if you push to main; the safety lives in CI +
   the deploy gate.

## On-call basics

When prod breaks:

1. Promote the previous deployment (fast lever), unless the release's
   migration notes mark it fix-forward-only.
2. Check the error reporter for the trace.
3. Check the database's query insights for slow or failing queries.
4. If a migration is the cause: PITR-restore to a fresh branch, verify,
   swap `DATABASE_URL`; revert the migration commit; redeploy.

## Things this workflow deliberately does NOT have

- **Pull requests / branch protection.** Push straight to main; safety
  lives in the kit's gates, CI, and the deploy gate. (Switch to PRs by
  deleting this line and editing the TL;DR.)
- **Separate staging environment.** Vercel previews + Postgres branches
  give 90% of the value with 10% of the maintenance.
- **Feature flags** beyond a per-tenant settings object. Revisit when
  traffic patterns justify gating.
- **Auto-migration on deploy.** Permanently off. See
  [Migrations](#migrations).
