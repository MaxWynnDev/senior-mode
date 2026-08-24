# Development & Deployment Workflow (go-service)

The source of truth for how code reaches production on this stack: a Go
service built into a container image, Postgres with pgx and sqlc, goose
migrations, GitHub Actions CI, deployed by image reference to Fly.io,
Cloud Run, or Kubernetes. Read it before changing CI or running a
migration. If anything here is wrong, fix the doc in the same commit as
the behavior change.

<!-- SETUP: this is the concrete version of the core WORKFLOW.md. It
assumes push-to-mainline behind a CI deploy gate and the local-heavy
verification model. Switch either decision here and in the agent's
project instructions. Replace <service>, <org>, <region>, <prod>, and
the deploy target with yours; delete the two targets you do not use. -->

## TL;DR

```
local edit
     │
     ├─ kit hooks                  LOC / print-debug / TODO gate, Senior-Checklist trailer
     ├─ pre-push                   gofmt + go vet + go test -race in the local-heavy model
     ▼
git push origin main
     │
     ├─ GitHub Actions: ci.yml     gofmt check, golangci-lint, go vet, sqlc diff,
     │                             go test -race (unit + integration on a Postgres
     │                             service container), govulncheck
     │      │ conclusion: success
     │      ▼
     ├─ build-image job            docker build (multi-stage, CGO_ENABLED=0),
     │                             push ghcr.io/<org>/<service>:<sha>
     │      │
     │      ▼
     └─ deploy job                 fly deploy --image <ref>
                                   | gcloud run deploy <service> --image <ref>
                                   | kubectl set image + rollout status
                                   then GET /readyz and /healthz on the new revision
```

One image per green SHA, deployed by SHA tag or digest. Nobody builds
on a laptop and pushes; nobody clicks anything.

DB migrations are intentionally OUTSIDE this loop. See
[Migrations](#migrations).

## What runs where

| Stage             | Where                              | What                                        |
| ----------------- | ---------------------------------- | ------------------------------------------- |
| Edit + commit     | Local machine (kit hooks)          | LOC / print-debug / TODO gate, trailer gate |
| Pre-push          | Local machine (kit hook)           | structural guards (+ gofmt, vet, `go test -race` in the local-heavy model) |
| CI                | GitHub Actions, on push to main    | lint + vet + sqlc diff + tests against ephemeral Postgres + govulncheck |
| Image build       | GitHub Actions, after CI green     | multi-stage Dockerfile, tagged with the SHA, pushed to the registry |
| Prod deploy       | GitHub Actions, after image push   | deploy by image reference; wait for the revision to report ready |
| Post-deploy smoke | GitHub Actions, same job           | `go run ./cmd/tools/smoke-test -base https://<prod>` |
| Migrations        | Local terminal, manual             | `scripts/migrate-prod.sh`                   |
| Error monitoring  | Sentry (or equivalent)             | Go SDK; release = git SHA baked in via `-ldflags -X` |

## Two verification models

Decide where heavy verification runs and say so in the agent's project
instructions, because `/go`, `/iterate`, and the app-verifier behave
differently under each.

| | Local-heavy (default) | Remote-heavy |
|---|---|---|
| `go build ./... && go vet ./...` | before every push, again in CI | CI only |
| `go test ./... -race -count=1` | before every push, again in CI | CI only; the pushed SHA is the first execution |
| Integration tests (`-tags integration`) | against a local Postgres | against the CI service container only |
| app-verifier | boots `go run ./cmd/<service>` here and curls it | watches the CI run, then probes the deployed revision |

Go's toolchain is small and fast enough that local-heavy costs seconds;
pick remote-heavy only when the machine cannot run Postgres.

## Local dev

```bash
go mod download
docker compose up -d postgres                                  # or any local Postgres 16
export DATABASE_URL='postgres://app:app@localhost:5432/app?sslmode=disable'
goose -dir migrations postgres "$DATABASE_URL" up
sqlc generate                                                  # after editing db/queries/*.sql or a migration
go run ./cmd/<service>                                         # listens on :8080
```

Go has no built-in dotenv. Load a gitignored `.env` only in `main` and
only when `APP_ENV` is empty or `development`; production reads real
environment variables. The `db` package refuses to open a pool to a host
that looks like production unless `APP_ENV=production`, so a copied prod
URL in a dev shell fails closed instead of connecting.

Connect locally as the same restricted role prod uses once RLS is on;
the owner role bypasses RLS and hides a missing tenant predicate.

## Pushing changes

```bash
gofmt -l .                                    # must print nothing
go vet ./... && go test ./... -race -count=1
git add <paths>
git commit -m "what changed and why

Senior-Checklist: ambiguity=pass summary=pass concurrency=pass regression=pass blast=green"
git push origin main
```

`concurrency=` is rarely `n/a` in Go: if the change touches a goroutine,
a channel, a shared map, or a transaction boundary, say what you checked.

CI re-runs every check on Linux with the toolchain pinned in `go.mod`.
A `cancelled` run means a later push superseded yours: your code ships
with THEIR deploy only if your SHA is an ancestor of the deployed one;
prove it with `git merge-base --is-ancestor <your-sha> <deployed-sha>`.

Watching CI from an agent session: never pipe the watcher.

```bash
gh run watch <id> --exit-status > watch.log 2>&1; echo "WATCH_EXIT=$?"
gh run view <id> --json status,conclusion
```

The deploy job should: run only on `push` to main after the test job
succeeds, refuse to deploy an image whose SHA is not the current
mainline tip (or an ancestor of it), serialize with a `concurrency`
group so two pushes cannot race, wait for the revision to report ready,
and fail the job if the smoke test fails (the platform is still serving
the new revision at that point; roll back per [On-call](#on-call-basics)).
A `PRODUCTION_DEPLOY_HOLD` marker file committed in a green SHA lets
the workflow complete WITHOUT deploying, as an interlock for a
migration rollout; the commit that satisfies the removal criteria
deletes it.

## CI green is not deployed

A green check on the SHA means the tests passed. It does not mean the
image was built, pushed, or is serving traffic. Confirm all three:

```bash
gh run view <id> --json jobs --jq '.jobs[] | {name, conclusion}'   # build-image and deploy both success
fly releases                                                       # Fly: newest release carries your image tag
gcloud run services describe <service> --region <region> --format 'value(status.latestReadyRevisionName)'
kubectl rollout status deployment/<service>                        # exits non-zero if the rollout stalled
curl -fsS https://<prod>/healthz                                   # reports the SHA you pushed
```

Bake the SHA into the binary with `-ldflags "-X main.version=$GITHUB_SHA"`
and return it from `/healthz`; then "is my code live" is one curl.

## The ship loop

`/ship` runs: audit, commit, push, watch CI to a green conclusion (fix
forward, max 3), confirm the image and deploy jobs for the SHA both
succeeded, confirm `/healthz` reports the SHA, then (unless `light`)
run the smoke tool against production. Behavior-changing updates take
this path; docs-only diffs, emergency rollbacks, and an explicit "quick
push" do not. Money-path and migration diffs always add `/pre-push`.

## Parallel sessions (git worktrees)

As in the core doc: the session registry banners on start, the tangle
guard blocks a non-incumbent's commit/push in a shared checkout,
`/worktree` isolates, and the lineage alert catches a stranded HEAD.
Go worktrees need nothing installed: the module cache is shared, so
`go test` works in a fresh worktree immediately. Ship from a worktree
with `git fetch origin && git rebase origin/main` then
`git push origin HEAD:main`.

## Staging on demand

There is no standing staging environment. When CI plus a local run is
not enough confidence:

- Fly: `fly deploy --app <service>-staging --image <ref>` into a second
  app whose `DATABASE_URL` points at a staging database (a branch, if
  your Postgres provider offers them; otherwise a restore).
- Cloud Run: `gcloud run deploy <service> --image <ref> --no-traffic
  --tag stage` gives a tagged URL that serves the new revision with
  zero production traffic. It runs against prod data unless you set a
  different `DATABASE_URL` on that revision; prefer a separate service
  for anything that writes.
- Kubernetes: a `staging` namespace with its own `Secret`;
  `kubectl apply -n staging`.

Rehearse migrations against the staging database first:
`goose -dir migrations postgres "$STAGING_DATABASE_URL" up`, then
`goose ... down` to prove the rollback, then `up` again.

Live wires: any OAuth tokens or webhook secrets copied into the staging
database are REAL. A send from staging is a real send.

## Migrations

**Migrations never run automatically.** goose is not in the Dockerfile,
not in a Fly `release_command`, not in a Kubernetes init container or a
Job triggered by the deploy, and never will be. Reasons:

- A migration that succeeds during a rollout can still leave a
  half-shipped schema if the rollout fails or is rolled back afterwards.
- A bad migration on a multi-tenant DB affects every customer at once.
  It needs human supervision.
- Two replicas starting at once would race the migration.

To apply pending migrations to prod:

```bash
git fetch origin
git merge-base --is-ancestor origin/main HEAD   # must exit 0
scripts/migrate-prod.sh                          # wraps goose; see below
```

Properties of the goose runner worth knowing:

- Applied versions live in the `goose_db_version` table. `goose status`
  prints every file with its applied timestamp or `Pending`; run it
  BEFORE (to see what will apply) and AFTER (to prove it did).
- `goose create <name> sql` mints a timestamp version. Two sessions can
  mint out-of-order timestamps; goose refuses a version older than the
  newest applied one unless `-allow-missing` is passed. Run `goose fix`
  before merging to renumber to sequential, and never pass
  `-allow-missing` in production.
- Each file runs in its own transaction by default, and Postgres DDL is
  transactional, so a failed `Up` rolls back cleanly and the version
  row is not written. `CREATE INDEX CONCURRENTLY` cannot run inside a
  transaction: mark the file `-- +goose NO TRANSACTION`, use
  `IF NOT EXISTS`, and know that a failure leaves an INVALID index to
  drop by hand.
- `goose down` undoes the newest version only. It exists to rehearse in
  staging; production is fix-forward.

`scripts/migrate-prod.sh` (write it before the first prod migration;
<!-- SETUP: name yours here -->) should:

1. Verify the URL looks like a prod host, and that the connecting role
   owns the tables (DDL as owner, runtime as the restricted role; never
   replace the runtime `DATABASE_URL` with the owner credential).
2. Run `goose status` and print every pending version with its
   filename and SQL hash; reject a pending version numbered below the
   newest applied one.
3. Demand a literal typed `APPLY`.
4. Re-fetch and repeat the ancestry check after the human review
   window.
5. Hold `pg_advisory_lock(<constant>)` on a side connection for the
   duration so two runners cannot interleave; re-read `goose status`
   under the lock and stop if it differs from what was approved.
6. Run `goose -dir migrations postgres "$DATABASE_URL" up`, then
   `goose status` again, and print both.

**Always migrate BEFORE** the deploy that depends on the schema.
Additive in one deploy, destructive in a follow-up after the code stops
referencing the column. Rehearse against staging first.

If a migration fails, **stop**. The transaction rolled back; inspect
the error, `goose status`, and the schema. Point-in-time restore only
for confirmed persisted corruption; a blind restore discards unrelated
writes made after the snapshot.

## Manual setup the platform needs

These live outside the repo. Do them once when standing up a new
environment.

### Registry and deploy target

1. Registry: `ghcr.io/<org>/<service>` (or Artifact Registry for Cloud
   Run). CI pushes with the workflow's `GITHUB_TOKEN` (`packages:
   write`); the deploy target pulls with a read-only credential.
2. Fly: `fly launch --no-deploy` once; `fly secrets set
   DATABASE_URL=...`; leave `[deploy] release_command` unset; set
   `kill_timeout` at least as long as your `Shutdown` deadline.
3. Cloud Run: create the service once with min instances per your
   latency budget and `DATABASE_URL` from Secret Manager. Cloud Run
   sends SIGTERM and allows 10 seconds by default, so `Shutdown` must
   finish inside that.
4. Kubernetes: a `Deployment` with readiness on `/readyz`, liveness on
   `/healthz`, `terminationGracePeriodSeconds` above your `Shutdown`
   deadline, and a `Secret` for `DATABASE_URL`.

### Error reporter

1. Create the project (Go platform); copy the DSN to the target's
   secrets.
2. Pass the SHA as the release in the SDK init.
3. Alert rule: error rate > 1% for 5 min to your on-call channel.

### Postgres

1. Confirm point-in-time restore retention is at least 7 days.
2. Test a restore once before launch. A backup you've never restored
   is not a backup.
3. Set the connection cap and size `pgxpool.MaxConns` times replica
   count below it, with headroom for the migration runner and a human.

### GitHub

1. Repository secrets: the deploy credential (Fly API token, a Google
   service account via workload identity, or a kubeconfig), sent only
   to the platform API and never logged.
2. `concurrency: { group: deploy-prod, cancel-in-progress: false }` on
   the deploy job.
3. No branch protection if you push to main; the safety lives in CI +
   the gated deploy job.

## On-call basics

When prod breaks:

1. Redeploy the previous image (fast lever), unless the release's
   migration notes mark it fix-forward-only:
   - Fly: `fly releases` to find the last good image, then
     `fly deploy --image <that ref>`.
   - Cloud Run: `gcloud run services update-traffic <service> --region
     <region> --to-revisions <previous-revision>=100`.
   - Kubernetes: `kubectl rollout undo deployment/<service>` then
     `kubectl rollout status deployment/<service>`.
2. Check the error reporter for the trace; check `/healthz` reports the
   SHA you expect.
3. Check the database's query insights for slow or failing queries and
   `pg_stat_activity` for a stuck migration or lock.
4. If a migration is the cause: do NOT `goose down` in production (data
   written since the migration is lost). Ship a forward migration that
   restores compatibility; PITR-restore only for confirmed corruption.

## Things this workflow deliberately does NOT have

- **Pull requests / branch protection.** Push straight to main; safety
  lives in the kit's gates, CI, and the gated deploy job. (Switch to
  PRs by deleting this line and editing the TL;DR.)
- **A standing staging environment.** A tagged revision or a second app
  on demand gives most of the value with none of the drift.
- **Auto-migration on deploy.** Permanently off. See
  [Migrations](#migrations).
- **Feature flags** beyond a per-tenant settings row. Revisit when
  traffic patterns justify gating.
- **Local image builds for deploy.** The registry only ever holds
  images CI built from a green SHA.
