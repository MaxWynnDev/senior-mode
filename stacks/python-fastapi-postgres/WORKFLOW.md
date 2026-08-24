# Development & Deployment Workflow (python-fastapi-postgres)

The source of truth for how code reaches production on this stack:
FastAPI in a Docker image, Postgres, Alembic migrations, GitHub Actions
CI that builds the image and deploys it to Fly.io (or Railway, or
Render). Read it before changing CI or running a migration. If anything
here is wrong, fix the doc in the same commit as the behavior change.

<!-- SETUP: this is the concrete version of the core WORKFLOW.md. It
assumes push-to-mainline behind a CI deploy gate, the local-heavy
verification model, and Fly.io as the deploy target. Switch any of the
three here and in the agent instructions file; the Railway and Render
variants are marked inline. -->

## TL;DR

```
local edit
     │
     ├─ kit hooks                  LOC / print-debug / TODO gate, Senior-Checklist trailer
     ├─ pre-push (kit hook)        structural guards; ruff + pyright + pytest in the local-heavy model
     ▼
git push origin main
     │
     ├─ GitHub Actions CI          ruff check + ruff format --check + pyright + pytest
     │                             (Postgres service container) + alembic upgrade head
     │                             + alembic check + one-head check + docker build
     │      │ conclusion: success
     │      ▼
     ├─ deploy job (same workflow) needs: [ci]; fly deploy --remote-only
     │                             --image-label <sha>; rolling, one machine at a time,
     │                             health check on /health before the next machine
     │      │
     │      ▼
     └─ fly releases               a release row for <sha>; `fly status` shows every
                                   machine on the new version
```

Nothing deploys unless the CI job is green: the platform never builds
on push by itself (Fly), or is configured to wait for checks (Railway,
Render). Nobody clicks anything.

DB migrations are intentionally OUTSIDE this loop. See
[Migrations](#migrations).

## Verification model

Local-heavy by default: `uv run ruff check .`, `uv run pyright`, and
`uv run pytest -q` run on the laptop before push and again in CI.
Remote-heavy teams skip the local run and treat the pushed SHA as the
first execution; say which one in the agent instructions file, because
`/go`, `/iterate`, and the app-verifier behave differently under each.

## What runs where

| Stage             | Where                              | What                                        |
| ----------------- | ---------------------------------- | ------------------------------------------- |
| Edit + commit     | Local machine (kit hooks)          | LOC / print-debug / TODO gate, trailer gate |
| Pre-push          | Local machine (kit hook)           | structural guards (+ ruff, pyright, pytest locally in the local-heavy model) |
| CI                | GitHub Actions, on push to main    | lint, types, tests against a Postgres service container, migration checks, image build |
| Prod deploy gate  | `needs: [ci]` in the workflow      | the deploy job exists only downstream of a green CI job |
| Prod deploy       | GitHub Actions + `fly deploy`      | exact-SHA image, rolling one machine at a time with health checks |
| Production QA     | GitHub Actions, on demand/nightly  | `smoke-test-*` scripts against the live host with the QA sandbox key |
| Migrations        | Local terminal, manual             | `scripts/migrate-prod.sh`                   |
| Error monitoring  | Sentry (or equivalent)             | FastAPI + SQLAlchemy integrations; release = git SHA |

## Local dev

```bash
uv sync                                  # creates .venv from uv.lock
docker compose up -d db                  # local Postgres on :5432  <!-- SETUP: or your local PG -->
cp .env.example .env                     # DATABASE_URL points at the local PG
uv run alembic upgrade head
uv run uvicorn app.main:app --reload     # :8000; /docs lists every route
```

`.env` is gitignored and never holds a production URL. The settings
module refuses to start when `APP_ENV != production` and `DATABASE_URL`
points at a host on the prod allowlist (`app/db/guard.py`); operational
scripts that must touch prod set `ALLOW_PROD_WRITES=1` on purpose.

Run the dev server as the same restricted role prod uses once RLS is
on; the owner role bypasses RLS and hides a missing tenant filter.

## Pushing changes

```bash
git add <paths>
git commit -m "what changed and why

Senior-Checklist: ambiguity=pass summary=pass concurrency=n/a regression=pass blast=green"
git push origin main
```

CI re-runs every check on Linux. A `cancelled` run means a later push
superseded yours: your code ships with THEIR deploy only if your SHA is
an ancestor of the deployed one; prove it with
`git merge-base --is-ancestor <your-sha> <deployed-sha>`.

Watching CI from an agent session: never pipe the watcher.

```bash
gh run watch <id> --exit-status > watch.log 2>&1; echo "WATCH_EXIT=$?"
gh run view <id> --json status,conclusion
```

CI green is not deployed. The deploy job must also succeed, and
`fly releases --image` must show a release whose image label is your
SHA. `fly status` shows the machines on the new version. For Railway or
Render, the deployment for your commit shows as active in the
dashboard, not merely "build succeeded".

The deploy job should: run only on `main`, use `concurrency` with
`cancel-in-progress: false` so two pushes never interleave deploys,
pass `--image-label <sha>` so releases are traceable to commits, and
fail if the health check does not pass within the wait timeout. A
`PRODUCTION_DEPLOY_HOLD` marker file committed in a green SHA lets the
workflow complete WITHOUT deploying, as an interlock for a migration
rollout; the commit that satisfies the removal criteria deletes it.

## The ship loop

`/ship` runs: audit, commit, push, watch CI to a green conclusion (fix
forward, max 3), confirm the deploy job succeeded and the release for
the SHA is active, then (unless `light`) run the `smoke-test-*` scripts
against production. Behavior-changing updates take this path; docs-only
diffs, emergency rollbacks, and an explicit "quick push" do not.
Money-path and migration diffs always add `/pre-push`.

## Parallel sessions (git worktrees)

As in the core doc: the session registry banners on start, the tangle
guard blocks a non-incumbent's commit/push in a shared checkout,
`/worktree` isolates, and the lineage alert catches a stranded HEAD.
A worktree has no `.venv`; run `uv sync` in it once (fast, the cache is
shared) or run commands from the main checkout. Two worktrees that each
generate an Alembic revision produce two heads; whoever pushes second
runs `alembic merge heads -m "<merge>"` or re-parents their revision.
Ship from a worktree with `git fetch origin && git rebase origin/main`
then `git push origin HEAD:main`.

## Staging on demand

There is no standing staging environment. When CI plus a local run is
not enough confidence:

<!-- SETUP: pick one and delete the others. -->

- **Fly:** a second app `<app>-staging` deployed with
  `fly deploy --app <app>-staging --image-label <sha>`, pointed at a
  fork of the prod database (`fly postgres create --fork-from <prod-pg>`
  for classic Fly Postgres, or your managed provider's branch or
  snapshot). Delete the fork afterwards; forks bill as full clusters.
- **Railway:** a PR environment, or a manually created environment
  with its own Postgres service seeded from a `pg_dump`.
- **Render:** a preview environment from `render.yaml`, with its own
  database seeded from a dump.

Rehearse the migration there first: point `DATABASE_URL` at the copy and
run `uv run alembic upgrade head`. Live wires still apply: third-party
tokens inside copied data are REAL, and shared buckets and rate-limit
stores are shared with prod.

## QA sweeps

A synthetic-data QA sandbox tenant with its own API key lets agents
exercise deployed targets with zero customer risk. The deterministic
pass is a pytest module marked `e2e` that hits every router's list
endpoint through `httpx` against a base URL (`uv run pytest -q -m e2e`);
the agent-driven pass reads `/openapi.json` and explores. Never sweep
during a rolling deploy: two versions answer at once and the diff is
noise. Agents scout; deterministic specs gate.

## Migrations

**Migrations never run automatically.** `alembic upgrade` is not in the
Dockerfile `CMD`, not in `fly.toml` `[deploy] release_command`, not in a
Railway or Render pre-deploy command, and never will be. Reasons:

- A migration that succeeds during a deploy can still leave a
  half-shipped schema if the rollout fails afterwards, and a rollback
  to the previous image does not roll the schema back with it.
- A bad migration on a multi-tenant DB affects every customer at once.
  It needs human supervision.

Alembic properties the runner relies on:

- The graph lives in `alembic/versions/`; every revision names its
  `down_revision`. The `alembic_version` table holds the applied
  watermark. Two revisions with the same parent are two heads, and
  `alembic upgrade head` refuses to run until they are merged. CI's
  one-head check catches this before it reaches a terminal:

  ```bash
  uv run alembic heads > heads.log 2>&1; echo "HEADS_EXIT=$?"
  [ "$(grep -c '(head)' heads.log)" -eq 1 ] || { cat heads.log; exit 1; }
  ```

- `alembic check` proves the models and the graph agree, but only
  against a database already at `head`; CI upgrades the service
  container first, then checks.
- Postgres DDL is transactional, and Alembic runs the whole upgrade in
  one transaction by default, so a failed step rolls the batch back.
  `ALTER TYPE ... ADD VALUE` and `CREATE INDEX CONCURRENTLY` are the
  exceptions: they need their own revision inside an
  `autocommit_block()`.

To apply pending migrations to prod:

```bash
git fetch origin
git merge-base --is-ancestor origin/main HEAD   # must exit 0
scripts/migrate-prod.sh
```

The sanctioned runner should:

1. Read the target from an explicit `MIGRATE_DATABASE_URL`, prefer an
   owner role for DDL, verify it resolves to the SAME database as the
   runtime URL, and never write the owner credential into the runtime
   secret.
2. Verify the host is on the prod allowlist and refuse anything else
   (staging has its own invocation).
3. Print `alembic current` and `alembic heads`, stop unless exactly one
   head, then print the pending range with
   `alembic history -r <current-rev>:head` and the SQL with
   `alembic upgrade <current-rev>:head --sql` for review, where
   `<current-rev>` is the id `alembic current` printed (offline `--sql`
   mode cannot resolve `current` on its own).
4. Demand a literal typed `APPLY`.
5. Re-fetch and repeat the ancestry check after the human review
   window.
6. Take `pg_advisory_xact_lock(<constant>)` in a wrapping transaction
   so two runners cannot interleave; re-read `alembic_version` under
   the lock; stop if it moved since the review.
7. Run `alembic upgrade head` and print `alembic current` afterwards.

**Always migrate BEFORE** the deploy that depends on the schema.
Additive in one deploy, destructive in a follow-up after the code stops
referencing the column. Rehearse on the staging copy first.

If a migration fails, **stop**. The transaction rolled back; inspect
the error, `alembic current`, and the schema. Point-in-time restore only
for confirmed persisted corruption; a blind restore discards unrelated
writes made after the snapshot.

## Manual setup the platform needs

These live outside the repo. Do them once when standing up a new
environment.

### Fly.io <!-- SETUP: or the Railway / Render block below -->

1. `fly launch --no-deploy` to create the app and `fly.toml`; set
   `[http_service]` with `internal_port = 8000`, a `/health` check,
   `min_machines_running = 1`, and no `release_command`.
2. Secrets: `fly secrets set DATABASE_URL=... SENTRY_DSN=...`; the
   runtime URL is the restricted app role, not the owner.
3. A deploy token (`fly tokens create deploy`) in the GitHub secret
   `FLY_API_TOKEN`.
4. Postgres: a managed provider with point-in-time restore, or classic
   Fly Postgres if you accept owning backups and failover.

### Railway / Render

1. Connect the repo; confirm the Dockerfile builder is used.
2. Auto-deploy: wait for GitHub checks, or off with the CI job
   deploying explicitly. Never both auto-deploy and a CI deploy.
3. No pre-deploy command. Health check path `/health`.

### Error reporter

1. Create the project (Python / FastAPI platform); copy the DSN to the
   platform secrets.
2. Set `release` to the git SHA in the SDK init; the deploy job passes
   it as a build arg.
3. Alert rule: error rate > 1% for 5 min to your on-call channel.

### Postgres

1. Two roles: an owner for migrations, a restricted role for the app.
2. Confirm point-in-time restore retention is at least 7 days.
3. Test a restore once before launch. A backup you have never restored
   is not a backup.

### GitHub

1. Secrets: the platform deploy token; the error reporter auth token
   if you upload release info. Sent only to those APIs, never logged.
2. No branch protection if you push to main; the safety lives in CI
   and the `needs: [ci]` deploy job.

## On-call basics

When prod breaks:

1. Redeploy the previous image (fast lever):
   `fly releases --image`, pick the last good ref,
   `fly deploy --image <ref>`. On Railway or Render, redeploy the prior
   deployment from the dashboard. Skip this if the release's migration
   notes mark it fix-forward-only.
2. Check the error reporter for the trace.
3. Check `pg_stat_activity` and the provider's query insights for slow
   or failing queries.
4. If a migration is the cause: PITR-restore to a fresh database,
   verify, swap `DATABASE_URL`; revert the migration commit; redeploy.

## Things this workflow deliberately does NOT have

- **Pull requests / branch protection.** Push straight to main; safety
  lives in the kit's gates, CI, and the gated deploy job. (Switch to PRs
  by deleting this line and editing the TL;DR.)
- **Separate staging environment.** A second app plus a database copy
  on demand gives 90% of the value with 10% of the maintenance.
- **Feature flags** beyond a per-tenant settings object. Revisit when
  traffic patterns justify gating.
- **Auto-migration on deploy.** Permanently off. See
  [Migrations](#migrations).
