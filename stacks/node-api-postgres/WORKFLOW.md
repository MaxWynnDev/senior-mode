# Development & Deployment Workflow (node-api-postgres)

The source of truth for how code reaches production on this stack: a
TypeScript HTTP service (Hono / Fastify / Express 5 / Nest) in a Docker
image on Fly.io (Railway and Render equivalents inline), Postgres with
Drizzle or Prisma migrations, GitHub Actions CI. Read it before changing
CI or running a migration. If anything here is wrong, fix the doc in the
same commit as the behavior change.

<!-- SETUP: this is the concrete version of the core WORKFLOW.md for a
headless service. It assumes push-to-mainline behind a CI deploy gate
and the local-heavy verification model; the two tables below name the
alternatives. Keep one model per decision here and in the agent
instructions file. Replace <app>, <org>, and the platform commands with
yours. -->

## TL;DR

```
local edit
     │
     ├─ kit hooks                  LOC / print-debug / TODO gate, Senior-Checklist trailer
     ├─ pre-push (husky)           structural guards; typecheck + lint + unit in the local-heavy model
     ▼
git push origin main
     │
     ├─ ci.yml                     typecheck + lint + unit + integration (Postgres service
     │                             container, migrations applied from zero) + AI eval gate
     │      │ conclusion: success
     │      ▼
     ├─ deploy.yml                 needs: ci. Builds the image with GIT_SHA baked in, pushes
     │                             ghcr.io/<org>/<app>:<sha>, then `fly deploy --image` that ref
     │      │
     │      ▼
     └─ Fly rolling deploy         one machine at a time, the /health check must pass, then
                                   `curl /health` confirms version == <sha>
```

Nothing deploys unless that exact SHA passed CI; nobody clicks anything.
The image is immutable and tagged by SHA, so rollback is a redeploy of
the previous tag (see [On-call basics](#on-call-basics)).

DB migrations are intentionally OUTSIDE this loop. See
[Migrations](#migrations).

## Deploy model

Push to the mainline behind the CI gate (default). `deploy.yml` uses
`needs: [ci]`, `if: github.ref == 'refs/heads/main'`, and
`concurrency: { group: deploy-prod, cancel-in-progress: false }` so two
pushes serialize instead of racing. PR-based teams keep the same file and
land on `main` by squash merge; nothing else changes.

| Platform | Deploy step | Rollback lever |
|---|---|---|
| Fly.io | `fly deploy --image ghcr.io/<org>/<app>:<sha> --strategy rolling` | `fly deploy --image ghcr.io/<org>/<app>:<previous-sha>` |
| Railway | `railway up --service <app>` (or the GitHub integration on `main`) | dashboard: redeploy the previous deployment |
| Render | `render.yaml` with `autoDeploy: false`, deploy hook called after CI | dashboard: rollback to the previous deploy |

## Two verification models

| | Local-heavy (default) | Remote-heavy |
|---|---|---|
| Typecheck / lint / unit | before push, again in CI | CI only; the pushed SHA is the first execution |
| Integration (Postgres) | `docker compose up -d postgres` then `pnpm test:integration` | the CI service container only |
| `/go` step 1 | runs the checks and boots the app for the app-verifier | adds tests as code; verification is "pending remote" |
| `/iterate` oracle | `pnpm test` | the `ci` job for the SHA |
| app-verifier | `pnpm dev`, then `curl` or `app.request()` against the changed routes | inspects `/health` and the changed routes on the deployed target after the release |

## What runs where

| Stage | Where | What |
|---|---|---|
| Edit + commit | Local machine (kit hooks) | LOC / print-debug / TODO gate, trailer gate |
| Pre-push | Local machine (husky) | structural guards (+ typecheck + lint + unit in the local-heavy model) |
| CI | GitHub Actions, on push | `pnpm typecheck`, `pnpm lint`, `pnpm test`, `pnpm test:integration` against `postgres:16` with migrations applied from zero, lockfile audit |
| Image build | GitHub Actions (`deploy.yml`) | `docker build --build-arg GIT_SHA=$GITHUB_SHA`, push to GHCR tagged by SHA |
| Prod deploy | GitHub Actions + platform | `fly deploy --image ...`, health check gate, rolling |
| Post-deploy smoke | GitHub Actions, same job | `pnpm exec tsx scripts/smoke-test-prod.ts` with the QA tenant's API key |
| Migrations | Local terminal, manual | `pnpm db:migrate:prod` |
| Error monitoring | Sentry (or equivalent) | Node SDK, `release = <sha>`; pino JSON logs shipped by the platform |

## Local dev

```bash
pnpm install
cp .env.example .env                     # DATABASE_URL points at the compose Postgres
docker compose up -d postgres            # postgres:16 on localhost:5432
pnpm db:migrate                          # drizzle-kit migrate (or prisma migrate dev) against local
pnpm dev                                 # tsx watch src/server.ts, on :3000
curl -s localhost:3000/health            # {"ok":true,"version":"dev"}
```

`.env` is gitignored and holds only the local database. Prod
credentials never live in a file on a laptop; the sanctioned runner
reads `DATABASE_URL_PROD` from the shell for one invocation, and the DB
module refuses to connect a non-production `NODE_ENV` to a host that
matches the prod pattern (fail-closed guard in `src/lib/env.ts`).

Connect the dev server as the same restricted role prod uses once RLS
is on; the owner role bypasses RLS and hides a missing wrapper locally.

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

**CI green is not deployed.** A green `ci` job next to a failed or
skipped `deploy` job is the usual shape of "why is prod stale". Confirm
the deploy for the exact SHA:

```bash
gh run view <id> --json jobs --jq '.jobs[] | {name, conclusion}'
curl -s https://<app>.fly.dev/health | jq -r .version   # must equal the SHA
fly releases --app <app>                                # or the platform's deploy list
```

A `PRODUCTION_DEPLOY_HOLD` marker file committed in a green SHA makes
`deploy.yml` complete WITHOUT deploying, as an interlock for a migration
rollout; the commit that satisfies the removal criteria deletes it.

## The ship loop

`/ship` runs: audit, commit, push, watch CI to a green conclusion (fix
forward, max 3), confirm `/health` reports the SHA, then (unless
`light`) run the smoke script against prod. Behavior-changing updates
take this path; docs-only diffs, emergency rollbacks, and an explicit
"quick push" do not. Money-path and migration diffs always add
`/pre-push`.

## Parallel sessions (git worktrees)

As in the core doc: the session registry banners on start, the tangle
guard blocks a non-incumbent's commit/push in a shared checkout,
`/worktree` isolates, and the lineage alert catches a stranded HEAD.
Worktrees share the compose Postgres; give each worktree its own
database name (`DATABASE_URL=.../app_<worktree>`) so integration tests
do not truncate each other's tables. Ship from a worktree with `git
fetch origin && git rebase origin/main` then `git push origin HEAD:main`.

## Staging on demand

There is no standing staging environment. When CI plus the integration
suite is not enough confidence (a migration with a backfill, a change to
the auth middleware):

```bash
fly apps create <app>-staging --org <org>                      # once
fly secrets set -a <app>-staging DATABASE_URL=<staging db url>
fly deploy -a <app>-staging --image ghcr.io/<org>/<app>:<sha>
```

The staging database is a Postgres branch (Neon) or a fresh database
restored from last night's dump (`pg_restore`), never the prod database.
Third-party tokens inside restored data are REAL: a send from staging is
a real send. Destroy the app (`fly apps destroy <app>-staging`) when
done; two staging apps drift into three.

## Smoke tests

`scripts/smoke-test-prod.ts` hits `/health`, one authenticated read with
the QA tenant's API key, and one idempotent write that the QA tenant
owns. It runs at the end of `deploy.yml` and from `/ship`. No browser
sweep: there is no browser surface. Deterministic checks gate; the
agent's exploratory pass is a `curl` session against the deployed
target, never against prod data outside the QA tenant.

## Migrations

**Migrations never run automatically.** Not in the Dockerfile, not in
the image entrypoint, not in `[deploy] release_command`, not in
`deploy.yml`. Reasons:

- A migration that runs during a deploy and then fails to get traffic
  leaves a half-shipped schema with no operator watching.
- A bad migration on a multi-tenant DB affects every customer at once.
  It needs human supervision.

To apply pending migrations to prod:

```bash
git fetch origin
git merge-base --is-ancestor origin/main HEAD   # must exit 0
DATABASE_URL_PROD=<owner url> pnpm db:migrate:prod
```

The sanctioned runner (`scripts/migrate-prod.ts`, run with `tsx`) should:

1. Use an owner connection for DDL, verify it targets the SAME database
   as the runtime URL, and verify the role owns the tables. Never swap
   the runtime `DATABASE_URL` for the owner credential.
2. Verify the host matches the prod pattern, and refuse otherwise.
3. Print every pending entry with its timestamp and SQL hash.
   Drizzle: journal entries in `drizzle/meta/_journal.json` whose
   `when` is greater than `max(created_at)` in
   `drizzle.__drizzle_migrations`; reject a `when` older than that
   watermark (the migrator silently skips a stale entry minted by a
   parallel session). Prisma: `prisma migrate status`, plus the
   runner's own checksum comparison of every applied file against
   `_prisma_migrations`; a mismatch aborts.
4. Demand a literal typed `APPLY`.
5. Re-fetch and repeat the ancestry check after the human review
   window.
6. Take a transaction-scoped advisory lock (`pg_advisory_xact_lock`) so
   two runners cannot interleave; re-read the database and the files
   under the lock; stop if anything differs from what was approved.
7. Apply. Drizzle: the migrator applies the SQL and the tracking rows
   together. Prisma: spawn `prisma migrate deploy` (never `migrate dev`,
   which can reset the database) with an explicit env allowlist; a
   failure records the failed file in `_prisma_migrations` and leaves
   earlier files applied. `CREATE INDEX CONCURRENTLY` cannot run inside
   a transaction and gets its own migration.

**Always migrate BEFORE** the deploy that depends on the schema.
Additive in one deploy, destructive in a follow-up after the code stops
referencing the column. The integration job applies every migration
from zero on each run, so a broken file is caught before it reaches the
runner. Rehearse on the staging app first when a backfill is involved.

If a migration fails, **stop**. Read the exact migration-table and
schema state before touching anything. Prisma: `prisma migrate resolve
--rolled-back <name>` after you have reverted by hand, or `--applied`
after you have completed it by hand. Point-in-time restore only for
confirmed persisted corruption; a blind restore discards unrelated
writes made after the snapshot.

## Manual setup the platform needs

These live outside the repo. Do them once when standing up a new
environment.

### Fly.io (Railway / Render equivalents in the deploy table)

1. `fly launch --no-deploy` to create the app and `fly.toml`; set
   `[http_service]` with `min_machines_running = 1` and a
   `[[http_service.checks]]` on `/health`. Leave `release_command` unset.
2. `fly secrets set DATABASE_URL=... SENTRY_DSN=...` (the runtime
   role's URL, not the owner's).
3. A deploy token (`fly tokens create deploy`) as the `FLY_API_TOKEN`
   repository secret. Railway: `RAILWAY_TOKEN`. Render: the deploy hook
   URL as a secret and `autoDeploy: false` in `render.yaml`.
4. Dockerfile: multi-stage on `node:22-slim`, pnpm pinned by the
   `packageManager` field and installed explicitly, `pnpm install
   --frozen-lockfile --prod` in the runtime stage, `ARG GIT_SHA` written
   to `APP_VERSION`, a non-root user, `CMD ["node", "dist/server.js"]`
   (exec form, so SIGTERM reaches the process and graceful shutdown
   drains the pool).

### Error reporter

1. Create the project (Node platform); copy the DSN to the platform
   secrets. Set `release` to the SHA from `APP_VERSION`.
2. Alert rule: error rate > 1% for 5 min to your on-call channel.

### Postgres

1. Two roles: an owner for migrations, a restricted role for runtime.
2. Point-in-time restore retention of at least 7 days; test a restore
   once before launch. A backup you have never restored is not a backup.
3. Connection budget: `pool.max` times machine count stays under the
   database's connection limit, or a pooler (PgBouncer, the provider's
   pooled endpoint) sits in front.

### GitHub

1. Secrets: the platform token, the QA tenant's smoke-test API key.
   GHCR push uses `GITHUB_TOKEN` with `packages: write`.
2. `ci.yml`: a `postgres:16` service container with a health check; the
   integration job runs migrations from zero, then `pnpm test:integration`.
3. No branch protection if you push to main; the safety lives in CI and
   `needs: [ci]`.

## On-call basics

When prod breaks:

1. Redeploy the previous image (fast lever):
   `fly deploy --image ghcr.io/<org>/<app>:<previous-sha>`. Find the SHA
   with `git log --oneline -5` or `fly releases`. Skip this only if the
   release's migration notes mark it fix-forward-only.
2. `fly logs -a <app>` and the error reporter for the trace.
3. The database's query insights or `pg_stat_statements` for slow or
   failing queries; `pg_stat_activity` when the pool is full.
4. If a migration is the cause: PITR-restore to a fresh branch or
   database, verify, swap `DATABASE_URL`; revert the migration commit;
   redeploy.

## Things this workflow deliberately does NOT have

- **Pull requests / branch protection.** Push straight to main; safety
  lives in the kit's gates, CI, and `needs: [ci]`. (Switch to PRs by
  deleting this line and editing the TL;DR.)
- **Separate staging environment.** On demand only, see above.
- **Auto-migration on deploy.** Permanently off. See
  [Migrations](#migrations).
- **A browser QA sweep.** No UI; the integration suite gates and the
  smoke script verifies the deployed target.
- **Blue/green.** Rolling with a health check is enough until traffic
  patterns justify `--strategy bluegreen`.
