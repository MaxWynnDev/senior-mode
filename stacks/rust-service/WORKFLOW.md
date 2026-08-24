# Development & Deployment Workflow (rust-service)

The source of truth for how code reaches production on this stack:
axum on tokio, sqlx migrations, Postgres, a container image built in
GitHub Actions and rolled out to Fly.io, Cloud Run, or Kubernetes. Read
it before changing CI or running a migration. If anything here is
wrong, fix the doc in the same commit as the behavior change.

<!-- SETUP: this is the concrete version of the core WORKFLOW.md. It
assumes push-to-mainline behind a CI deploy job and the local-heavy
verification model. Switch either decision here and in the agent's
project instructions. Keep ONE of the three deploy targets below and
delete the other two. -->

## TL;DR

```
local edit
     │
     ├─ kit hooks                LOC / print-debug / TODO gate, Senior-Checklist trailer
     ├─ pre-push                 cargo fmt --check, cargo clippy -D warnings, cargo test
     │                           (local-heavy model; structural guards only in remote-heavy)
     ▼
git push origin main
     │
     ├─ GitHub Actions: check    fmt, clippy, cargo sqlx prepare --check,
     │                           sqlx migrate run + cargo test against a Postgres
     │                           service container, cargo deny check (optional)
     │      │ conclusion: success
     │      ▼
     ├─ GitHub Actions: image    docker build (multi-stage, SQLX_OFFLINE=true),
     │                           tag = git SHA, push to the registry
     │      │
     │      ▼
     └─ GitHub Actions: deploy   fly deploy --image <ref>  |  gcloud run deploy --image <ref>
                                 |  kubectl set image + rollout status
                                 health check on /readyz; rollback = the previous image tag
```

One image per SHA. The deploy job deploys the image the check job
proved, never a rebuild. Nobody clicks anything.

DB migrations are intentionally OUTSIDE this loop. See
[Migrations](#migrations).

## Branching model

Push to the mainline. No pull requests, no branch protection. Safety
lives in the ship loop in front (audit, commit gate), CI, the deploy
job, and image rollback. Parallel sessions isolate in worktrees and
land by rebase + push. <!-- SETUP: or PRs with a protected branch; if
so, CI runs on the PR and merge deploys. Say which. -->

## Two verification models

| | Local-heavy (default) | Remote-heavy |
|---|---|---|
| fmt / clippy / test | run locally before push, again in CI | CI only; the pushed SHA is the first execution |
| `/go` step 1 | runs the checks and boots `cargo run` here | adds tests as code; verification is "pending remote" |
| `/iterate` oracle | `cargo test` or `cargo clippy` locally | the check job for the SHA |
| app-verifier | `cargo run` + curl the changed routes | inspects the deployed revision |
| Good for | laptops with the toolchain and a local Postgres | shared or weak machines, long compiles, "CI is the oracle" teams |

A full `cargo build --release` is minutes, not seconds; the local-heavy
model runs `cargo check` and `cargo test` (debug profile) locally and
leaves the release build to CI. Remote-heavy teams may add a guard that
denies heavy local commands in agent sessions; that is a project
decision, not a kit default.

## What runs where

| Stage             | Where                              | What                                              |
| ----------------- | ---------------------------------- | ------------------------------------------------- |
| Edit + commit     | Local machine (kit hooks)          | LOC / print-debug / TODO gate, trailer gate       |
| Pre-push          | Local machine (kit hook)           | fmt + clippy + test in the local-heavy model      |
| CI: check         | GitHub Actions, on push to main    | fmt, clippy, prepare --check, migrate + test, deny |
| CI: image         | GitHub Actions, after check        | multi-stage build, SHA tag, registry push         |
| CI: deploy        | GitHub Actions, after image        | platform rollout of that exact tag                |
| Staging           | On demand                          | same image, a staging app + a branch or copy of Postgres |
| Migrations        | Local terminal, manual             | `scripts/migrate-prod.sh`                         |
| Error monitoring  | Sentry (or equivalent)             | `sentry` crate + `tracing` layer; release = git SHA |

## Local dev

```bash
rustup show                                     # toolchain from rust-toolchain.toml
cargo install sqlx-cli --no-default-features --features rustls,postgres
docker compose up -d postgres                   # or any local Postgres
cp .env.example .env                            # DATABASE_URL=postgres://...@localhost/<app>_dev
sqlx database create
sqlx migrate run
cargo run                                       # binds <HOST>:<PORT>
```

`.env` is read by `sqlx-cli`, by the `query!` macros at compile time,
and by the app through `dotenvy` in dev only. It holds the DEV
database. The prod URL never lives in a file on a laptop; the runner
reads it from `<secret manager>` at invocation. A fail-closed guard in
`db::connect` refuses a URL that matches the prod host pattern unless
`APP_ENV=production`.

After editing any `query!` or any migration: `cargo sqlx prepare` and
commit `.sqlx/`. The macros need the migrations applied locally before
they compile; `sqlx migrate run` first.

## Pushing changes

```bash
git add <paths>
git commit -m "what changed and why

Senior-Checklist: ambiguity=pass summary=pass concurrency=n/a regression=pass blast=green"
git push origin main
```

CI re-runs every check on Linux against a fresh Postgres. The deploy
job runs only when the check job's `conclusion` is `success` for the
same SHA. A `cancelled` run means a later push superseded yours: your
code ships with THEIR deploy only if your SHA is an ancestor of the
deployed one; prove it with
`git merge-base --is-ancestor <your-sha> <deployed-sha>`.

Watching CI from an agent session: never pipe the watcher.

```bash
gh run watch <id> --exit-status > watch.log 2>&1; echo "WATCH_EXIT=$?"
gh run view <id> --json status,conclusion
```

**CI green is not deployed.** Confirm the running image is the SHA:

```bash
fly status --json | jq -r '.Machines[].config.image'                                 # Fly.io
gcloud run services describe <svc> --format 'value(status.latestReadyRevisionName)'  # Cloud Run
kubectl get deploy <name> -o jsonpath='{.spec.template.spec.containers[0].image}'    # Kubernetes
```

The deploy job should: verify the green SHA is still the mainline tip
(or an ancestor), refuse to regress a newer deployment, serialize
parallel pushes with a concurrency group, and wait for the rollout to
report healthy. A `PRODUCTION_DEPLOY_HOLD` marker file committed in a
green SHA lets the workflow complete WITHOUT deploying, as an interlock
for a migration rollout; the commit that satisfies the removal criteria
deletes it.

## The ship loop

`/ship` runs: audit, commit, push, watch CI to a green conclusion (fix
forward, max 3), confirm the deployed image is the SHA, then (unless
`light`) curl the changed routes on the deployed target with the QA
credential. Behavior-changing updates take this path; docs-only diffs,
emergency rollbacks, and an explicit "quick push" do not. Money-path
and migration diffs always add `/pre-push`.

## Parallel sessions (git worktrees)

As in the core doc: the session registry banners on start, the tangle
guard blocks a non-incumbent's commit/push in a shared checkout,
`/worktree` isolates, and the lineage alert catches a stranded HEAD.
Each worktree has its own `target/` unless you set `CARGO_TARGET_DIR`
to a shared path; sharing it is faster and safe because cargo locks the
directory. Ship from a worktree with `git fetch origin && git rebase
origin/main` then `git push origin HEAD:main`.

Two sessions running `sqlx migrate add` mint two timestamps in either
order. Rebase, run `sqlx migrate info` locally, and make sure the file
you are adding is the newest version before pushing.

## Staging on demand

There is no standing staging environment. When CI is not enough
confidence (a migration, a money path, a new tower layer):

```bash
scripts/stage-up.sh <sha>            # staging app + Postgres branch or copy + the SHA's image
scripts/stage-up.sh <sha> --migrate  # also sqlx migrate run against the STAGING database
scripts/stage-down.sh                # list stage resources (dry run)
scripts/stage-down.sh --apply        # delete them
```

Properties worth knowing:

- The staging app runs the exact image CI built; nothing is rebuilt.
- Staging Postgres is a branch (Neon) or a restored snapshot of prod.
  It is the only place `sqlx migrate revert` is allowed.
- Whatever the staging environment lacks (error reporting, third-party
  secrets) is off by design. OAuth tokens inside copied data are REAL;
  a send from staging is a real send.

## Migrations

**Migrations never run automatically.** Not in the Dockerfile, not in
a Fly `release_command`, not in a Kubernetes init container, not via
`sqlx::migrate!().run()` at service start. Reasons:

- A migration that succeeds during a rollout can still leave a
  half-shipped schema if the rollout fails afterwards.
- A bad migration on a multi-tenant DB affects every customer at once.
  It needs human supervision.

To apply pending migrations to prod:

```bash
git fetch origin
git merge-base --is-ancestor origin/main HEAD   # must exit 0
scripts/migrate-prod.sh
```

The sanctioned runner wraps `sqlx migrate run` and should:

1. Read the prod URL from `<secret manager>`, never from the shell's
   `DATABASE_URL`. Verify the host matches the prod pattern and that
   the role owns the tables (DDL as the owner role, runtime as a
   restricted role; objects a migration creates must be granted to the
   app role).
2. Run `sqlx migrate info` and print it: every applied version with its
   description, every pending version. Refuse if any pending version is
   older than the newest applied one.
3. Print each pending file's SQL and sha256. sqlx itself refuses to run
   when an applied file's checksum differs from the row in
   `_sqlx_migrations`; an edited historic migration is fixed by a NEW
   file, never by touching the table.
4. Demand a literal typed `APPLY`.
5. Re-fetch and repeat the ancestry check after the human review
   window.
6. Run `sqlx migrate run`. sqlx takes a Postgres advisory lock so two
   runners serialize, and applies each file in its own transaction
   unless the file starts with `-- no-transaction`
   (`CREATE INDEX CONCURRENTLY` needs that, alone in its file).
7. Run `sqlx migrate info` again and stop if anything is still pending.
8. Confirm the committed `.sqlx/` cache was prepared against this
   schema (`cargo sqlx prepare --check` in CI already proves it).

Forward-only. `sqlx migrate revert` reverts one migration and exists
for staging and dev; in prod a bad migration is undone by a new
migration.

**Always migrate BEFORE** the deploy that depends on the schema.
Additive in one deploy, destructive in a follow-up after the code stops
referencing the column. Rehearse with `scripts/stage-up.sh --migrate`
first.

If a migration fails, **stop**. The file's transaction rolled back;
inspect the error, `_sqlx_migrations`, and the schema. Point-in-time
restore only for confirmed persisted corruption; a blind restore
discards unrelated writes made after the snapshot.

## Manual setup the platform needs

These live outside the repo. Do them once when standing up a new
environment. Keep the section for your target and delete the others.

### Fly.io

1. `fly launch --no-deploy` once; commit `fly.toml`. No
   `[deploy] release_command`; migrations are manual.
2. `fly secrets set DATABASE_URL=... APP_ENV=production`.
3. Health check on `/readyz` in `fly.toml`; rollout strategy `rolling`
   (or `canary` / `bluegreen` once traffic justifies it).
4. A deploy token in the GitHub secret `FLY_API_TOKEN`.

### Cloud Run

1. An Artifact Registry repo; the service account that deploys can
   push images and update the service, nothing else.
2. Secrets mounted from Secret Manager, not env vars in the console.
3. Deploy with `--no-traffic`, then `gcloud run services update-traffic
   --to-latest` after the health check; the previous revision stays
   for rollback.
4. Min instances 1 if cold-start latency matters; concurrency tuned to
   the pool size.

### Kubernetes

1. A `Deployment` with readiness on `/readyz`, liveness on `/healthz`,
   `terminationGracePeriodSeconds` longer than the longest request.
2. The service handles SIGTERM through
   `axum::serve(..).with_graceful_shutdown(..)` so in-flight requests
   finish during a rollout.
3. Secrets from the cluster's secret store; the deploy job runs
   `kubectl set image` + `kubectl rollout status`.

### Postgres

1. `sqlx database create` once per environment as the owner role;
   create the restricted runtime role and its grants by migration.
2. Pool size per instance times instance count stays under
   `max_connections` with headroom for the runner and a psql session.
3. Point-in-time restore retention of at least 7 days; test a restore
   once before launch. A backup you've never restored is not a backup.

### GitHub

1. Registry credentials and the platform deploy token as repository
   secrets (sent only to the platform API, never logged).
2. `Swatinem/rust-cache` in the check job; without it clippy plus tests
   rebuild every dependency on every push.
3. No branch protection if you push to main; the safety lives in CI +
   the deploy job.

## On-call basics

When prod breaks:

1. Redeploy the previous image tag (fast lever): `fly deploy --image
   <previous>`, `gcloud run services update-traffic --to-revisions
   <previous>=100`, or `kubectl rollout undo`. Unless the release's
   migration notes mark it fix-forward-only.
2. Check the error reporter for the trace; `tracing` spans carry the
   request id.
3. Check `pg_stat_activity` and the slow-query log; a pool exhausted by
   a hung upstream looks like a crash.
4. If a migration is the cause: PITR-restore to a fresh instance or
   branch, verify, swap `DATABASE_URL`; land a corrective migration;
   redeploy.

## Things this workflow deliberately does NOT have

- **Pull requests / branch protection.** Push straight to main; safety
  lives in the kit's gates, CI, and the deploy job. (Switch to PRs by
  deleting this line and editing the TL;DR.)
- **Separate staging environment.** On-demand staging with the same
  image gives most of the value with a fraction of the maintenance.
- **Feature flags** beyond a per-tenant settings row. Revisit when
  traffic patterns justify gating.
- **Auto-migration on deploy.** Permanently off. See
  [Migrations](#migrations).
- **Down migrations in prod.** Forward-only; `revert` is a staging tool.
