# Development & Deployment Workflow (rails-postgres)

The source of truth for how code reaches production on this stack:
Rails on Postgres, ActiveRecord migrations, a Docker image deployed with
Kamal 2 (or Fly.io / Render), GitHub Actions CI. Read it before changing
CI or running a migration. If anything here is wrong, fix the doc in the
same commit as the behavior change.

<!-- SETUP: this is the concrete version of the core WORKFLOW.md. It
assumes push-to-mainline behind a CI deploy gate, Kamal 2 as the deploy
tool, and the local-heavy verification model. Switch any of the three
here and in AGENTS.md. Fly and Render variants are marked inline. -->

## TL;DR

```
local edit
     │
     ├─ kit hooks                  LOC / print-debug / TODO gate, Senior-Checklist trailer
     ├─ pre-push                   rubocop + brakeman + rspec locally in the local-heavy model
     ▼
git push origin main
     │
     ├─ GitHub Actions CI          rubocop, brakeman, bundler-audit, rspec against a
     │                             postgres service container, system specs (headless
     │                             Chrome), schema drift check (db/schema.rb unchanged
     │                             after db:migrate)
     │      │ conclusion: success
     │      ▼
     ├─ deploy job (same workflow, needs: [test])
     │                             kamal deploy from the runner, image tagged with the
     │                             exact SHA that passed; concurrency group "production"
     │                             so parallel pushes serialize
     │      │
     │      ▼
     └─ kamal-proxy               boots the new container, polls /up, switches traffic,
                                   keeps the previous image on the host for rollback
```

Nobody clicks anything. The deploy job is the gate: it does not run
unless CI's `test` job succeeded for that SHA.

DB migrations are intentionally OUTSIDE this loop. See
[Migrations](#migrations).

## Deploy model

Push to the mainline. No pull requests, no branch protection; safety
lives in the kit's gates, CI, the deploy job's `needs:`, and
`kamal rollback`. Parallel sessions isolate in worktrees and land by
rebase + push. <!-- SETUP: for PRs, delete this paragraph, make the
deploy job trigger on push to main only, and let CI run on
pull_request. -->

Platform variants of the deploy step:

- **Kamal 2** (default): the CI deploy job has the SSH private key,
  `KAMAL_REGISTRY_PASSWORD`, and `RAILS_MASTER_KEY` as secrets and runs
  `bin/kamal deploy`. `config/deploy.yml` pins the servers; the image
  tag is the git SHA.
- **Fly.io**: the deploy job runs `flyctl deploy --remote-only` with
  `FLY_API_TOKEN`. Remove `release_command = "bin/rails db:migrate"`
  from `fly.toml` if `fly launch` wrote it.
- **Render**: a `render.yaml` blueprint; set auto-deploy to wait for CI
  checks (or trigger the deploy hook URL from the deploy job) and leave
  the pre-deploy command EMPTY.

## Two verification models

| | Local-heavy (default) | Remote-heavy |
|---|---|---|
| rubocop / brakeman / rspec | run locally before push, again in CI | CI only; the pushed SHA is the first execution |
| `/go` step 1 | runs the checks and boots `bin/dev` here | adds specs as code; verification is "pending remote" |
| `/iterate` oracle | `bundle exec rspec <file>` | the CI `test` job for the SHA |
| app-verifier | `bin/dev`, then curl `/up` and the changed routes | watches the CI run, then inspects the deployed host via `kamal app logs` |
| Good for | laptops with Ruby + Postgres installed | shared or weak machines, strict "CI is the oracle" teams |

Say which one applies in AGENTS.md. A remote-heavy team may add a
PreToolUse guard that denies `bundle exec rspec` and `bin/dev` in agent
sessions; that is a project decision, not a kit default.

## What runs where

| Stage             | Where                              | What                                        |
| ----------------- | ---------------------------------- | ------------------------------------------- |
| Edit + commit     | Local machine (kit hooks)          | LOC / print-debug / TODO gate, trailer gate |
| Pre-push          | Local machine                      | `bundle exec rubocop`, `bundle exec brakeman -q`, `bundle exec rspec` (local-heavy) |
| CI                | GitHub Actions, on push to main    | lint, security scan, dependency audit, specs + system specs, schema drift |
| Prod deploy gate  | The deploy job's `needs: [test]`   | no green test job, no deploy job            |
| Prod deploy       | GitHub Actions + Kamal             | exact-SHA image, health-checked container swap |
| Production QA     | GitHub Actions, on demand/nightly  | Capybara page sweep against the live site with the QA sandbox login |
| Migrations        | Local terminal, manual             | `scripts/migrate-prod.sh`                   |
| Error monitoring  | Sentry, Honeybadger, or equivalent | Ruby SDK; release = git SHA                 |

## Local dev

```bash
bundle install
bin/rails db:prepare                     # creates + migrates the dev and test databases
bin/dev                                  # Puma on :3000 plus Procfile.dev watchers
bundle exec rspec                        # or bin/rails test
```

`config/database.yml` reads `DATABASE_URL` when set. Keep the production
URL OUT of your shell profile and out of `.env`; the migration wrapper
takes it explicitly. Development and test connect to local databases
by name. A fail-closed guard in `config/initializers/database_guard.rb`
aborts boot when `Rails.env` is not production and the database host
matches the prod host pattern.

`config.active_record.migration_error = :page_load` (the default in
development) turns a pending migration into a full-page error, so a
forgotten `db:migrate` is loud. RSpec's `rails_helper` calls
`ActiveRecord::Migration.maintain_test_schema!`, which loads
`db/schema.rb` into the test database; that file must be committed and
current.

## Pushing changes

```bash
git add <paths>
git commit -m "what changed and why

Senior-Checklist: ambiguity=pass summary=pass concurrency=n/a regression=pass blast=green"
git push origin main
```

CI re-runs every check on Linux against a fresh Postgres. A `cancelled`
run means a later push superseded yours: your code ships with THEIR
deploy only if your SHA is an ancestor of the deployed one; prove it
with `git merge-base --is-ancestor <your-sha> <deployed-sha>`.

Watching CI from an agent session: never pipe the watcher.

```bash
gh run watch <id> --exit-status > watch.log 2>&1; echo "WATCH_EXIT=$?"
gh run view <id> --json status,conclusion
```

**CI green is not deployed.** Green means the `test` job passed. The
deploy job is a separate step that can fail (registry auth, SSH, a
container that never answers `/up`), and Kamal keeps the OLD container
serving when that happens. Confirm the deploy for the exact SHA:

```bash
gh run view <id> --json jobs --jq '.jobs[] | select(.name=="deploy") | .conclusion'
bin/kamal app details        # running container's image tag must equal the SHA
curl -fsS https://<host>/up  # 200
```

Fly: `fly releases` shows the release for the SHA and its status.
Render: the deploy list in the dashboard, or `render deploys list`.

## The ship loop

`/ship` runs: audit, commit, push, watch CI to a green conclusion (fix
forward, max 3), confirm the deploy job reached success and the running
image tag equals the SHA, then (unless `light`) dispatch the production
QA sweep. Behavior-changing updates take this path; docs-only diffs,
emergency rollbacks, and an explicit "quick push" do not. Money-path and
migration diffs always add `/pre-push`.

## Parallel sessions (git worktrees)

As in the core doc: the session registry banners on start, the tangle
guard blocks a non-incumbent's commit/push in a shared checkout,
`/worktree` isolates, and the lineage alert catches a stranded HEAD.
Worktrees share the installed gems (bundler resolves from the same
Ruby), but each needs its own dev database if two sessions migrate at
once: set `DATABASE_URL=postgres://localhost/<app>_dev_<branch>` in the
worktree's `.env.local` and `bin/rails db:prepare` there. Ship from a
worktree with `git fetch origin && git rebase origin/main` then
`git push origin HEAD:main`.

Two worktrees that both generate migrations will both edit
`db/schema.rb`. Do not hand-merge the schema file: rebase, run
`bin/rails db:migrate` (which regenerates it), commit the result.

## Staging on demand

There is no standing staging environment. When CI plus a local run is
not enough confidence for a change:

- **Kamal**: a second destination, `config/deploy.staging.yml`, pointing
  at a cheap host and a staging database. `bin/kamal deploy -d staging`
  deploys the working tree; `bin/kamal app exec -d staging --reuse
  "bin/rails db:migrate"` rehearses the migration. Tear it down with
  `bin/kamal app remove -d staging`.
- **Fly / Render**: a second app or a preview environment on a branch,
  with its own database. Render preview environments and Fly
  `fly deploy --app <app>-staging` both work.
- The staging database is a `pg_dump | pg_restore` of prod (or a
  provider snapshot) with sensitive columns scrubbed by
  `scripts/scrub-staging.rb` before anyone points a browser at it.
  Live wires: OAuth tokens inside restored data are REAL. Never run a
  send or a payout from staging.

## QA sweeps

A synthetic-data QA sandbox account lets agents exercise deployed
targets with real integrations and zero customer risk. The
deterministic sweep is a Capybara system spec that visits every
`GET` route from `bin/rails routes` under the sandbox login and asserts
no 5xx and no JavaScript console errors; it also runs in gating CI
against the local server. The nightly workflow points the same spec at
production. Agents scout; deterministic specs gate.

## Migrations

**Migrations never run automatically.** Remove the `db:prepare` line
from `bin/docker-entrypoint`, keep `release_command` out of `fly.toml`,
and leave Render's pre-deploy command empty. Reasons:

- A migration that runs at container boot runs once per container, on
  every host, racing the previous version still serving traffic.
- A bad migration on a multi-tenant DB affects every customer at once.
  It needs human supervision.

To apply pending migrations to prod:

```bash
git fetch origin
git merge-base --is-ancestor origin/main HEAD   # must exit 0
scripts/migrate-prod.sh
```

What the runner relies on, and what the wrapper adds:

1. Rails tracks applied versions in the `schema_migrations` table. The
   version is the timestamp in the filename, and `db/schema.rb`'s
   `define(version:)` header records the highest one. That version is
   the watermark: a new migration must carry a timestamp newer than the
   last applied one.
2. `bin/rails db:migrate` applies EVERY pending version, including one
   older than the current watermark (a migration merged from a parallel
   session). It is not silently skipped; it runs out of order. The
   wrapper prints `db:migrate:status` before applying so a stray `down`
   below the newest `up` is visible and gets a human decision.
3. On Postgres each migration runs inside its own transaction unless the
   file declares `disable_ddl_transaction!` (required for
   `algorithm: :concurrently`). A failed transactional migration rolls
   back cleanly; a failed concurrent index leaves an INVALID index that
   must be dropped before re-running.
4. Rails takes a Postgres advisory lock for the duration of `db:migrate`,
   so two runners raise `ActiveRecord::ConcurrentMigrationError` instead
   of interleaving.
5. `strong_migrations` runs inside the migration and refuses unsafe DDL
   before it reaches the database.
6. Production does not dump `db/schema.rb` after migrating
   (`dump_schema_after_migration = false`); the committed schema is the
   record.

The wrapper (`scripts/migrate-prod.sh`) must: refuse unless
`DATABASE_URL` (or the Kamal destination) matches the prod host pattern;
run `db:migrate:status` and print the pending versions; demand a literal
typed `APPLY`; re-fetch and repeat the ancestry check after the review
window; run `db:migrate`; run `db:migrate:status` again and fail if any
version is still `down`. <!-- SETUP: choose whether it runs locally with
an explicit DATABASE_URL, or through `bin/kamal app exec --reuse
--primary "bin/rails db:migrate"` when the database is only reachable
from the app hosts. -->

**Always migrate BEFORE** the deploy that depends on the schema.
Additive in one deploy, destructive in a follow-up after the code stops
referencing the column (`ignored_columns` first). Rehearse against
staging first.

If a migration fails, **stop**. Inspect the error, `db:migrate:status`,
and the table definition in `psql`. Migrations are forward-only in
production: write a new migration that repairs, do not `db:rollback`
against prod (the `down` was never rehearsed, and the previous container
may already depend on the new column).

## Manual setup the platform needs

These live outside the repo. Do them once when standing up a new
environment.

### Kamal

1. A host with Docker and SSH access for the deploy key; `bin/kamal
   setup` once.
2. A container registry (GHCR, Docker Hub) with a push token in
   `.kamal/secrets` as `KAMAL_REGISTRY_PASSWORD`.
3. `RAILS_MASTER_KEY` in the secrets file, never in `deploy.yml`.
4. `proxy: ssl: true, host: <domain>` in `deploy.yml` so kamal-proxy
   provisions the certificate; DNS pointed at the host first.
5. Postgres as a Kamal accessory on the same host for small apps, or a
   managed instance with point-in-time restore for anything with money
   in it.

### Error reporter

1. Create the project (Ruby / Rails platform); the DSN goes in
   credentials or the Kamal env, not in source.
2. Set `release` to the git SHA (`ENV["KAMAL_VERSION"]` inside a
   Kamal-deployed container, or the platform's SHA variable).
3. Alert rule: error rate > 1% for 5 min to your on-call channel.

### Postgres

1. Confirm point-in-time restore retention is at least 7 days.
2. Test a restore once before launch. A backup you've never restored
   is not a backup.

### GitHub

1. Repository secrets: the deploy SSH private key, the registry token,
   `RAILS_MASTER_KEY` (sent only to the Kamal process, never echoed).
2. A `concurrency: production` group on the deploy job so pushes
   serialize.
3. No branch protection if you push to main; the safety lives in CI and
   the deploy job's `needs:`.

## On-call basics

When prod breaks:

1. `bin/kamal rollback <previous-sha>` (fast lever): swaps to an image
   still on the host, no build. `bin/kamal app containers` lists what is
   there. Fly: `fly releases` then `fly deploy --image <previous image
   ref>`. Render: Rollback on the deploy in the dashboard. Rollback
   restores CODE only; the schema stays where the last migration left
   it, which is why migrations are additive-first.
2. Check the error reporter for the trace; `bin/kamal app logs -f` for
   the container.
3. Check `pg_stat_activity` and `pg_stat_statements` for slow or
   blocked queries; a migration holding a lock shows up here.
4. If a migration is the cause: fix forward with a repairing migration
   through the same wrapper. Point-in-time restore only for confirmed
   persisted corruption; a blind restore discards unrelated writes made
   after the snapshot.

## Things this workflow deliberately does NOT have

- **Pull requests / branch protection.** Push straight to main; safety
  lives in the kit's gates, CI, and the deploy job's `needs:`. (Switch
  to PRs by deleting this line and editing the TL;DR.)
- **Separate staging environment.** A second Kamal destination on
  demand gives most of the value at a fraction of the maintenance.
- **Feature flags** beyond a per-account settings column. Revisit when
  traffic patterns justify gating.
- **Auto-migration on deploy.** Permanently off. See
  [Migrations](#migrations).
- **`db:rollback` in production.** Forward-only. See above.
