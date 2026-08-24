# Development & Deployment Workflow (django-postgres)

The source of truth for how code reaches production on this stack:
Django in a Docker image, Postgres, Django migrations, GitHub Actions
CI, a container platform (Fly.io, Railway, or Render). Read it before
changing CI or running a migration. If anything here is wrong, fix the
doc in the same commit as the behavior change.

<!-- SETUP: this is the concrete version of the core WORKFLOW.md. It
assumes push-to-mainline behind a CI deploy gate. Pick one of the two
verification models below and one platform, delete the other branches,
and mirror the choice in AGENTS.md. -->

## TL;DR

```
local edit
     │
     ├─ kit hooks                  LOC / print-debug / TODO gate, Senior-Checklist trailer
     ├─ pre-push (git hook)        structural guards; ruff + pyright + pytest in the local-heavy model
     ▼
git push origin main
     │
     ├─ GitHub Actions: ci         uv sync --locked; ruff check; ruff format --check; pyright;
     │                             makemigrations --check --dry-run; migrate + pytest against a
     │                             Postgres service container; docker build (no push)
     │      │ conclusion: success
     │      ▼
     ├─ GitHub Actions: deploy     needs: ci. Builds the image tagged with the exact SHA,
     │                             pushes it, then tells the platform to roll it out
     │                             (fly deploy --image, railway up, or the Render deploy hook)
     │      │
     │      ▼
     └─ platform rollout           rolling replace behind the health check; /healthz on the
                                   new machines reports the SHA that CI passed
```

The deploy job lives in the same workflow as `ci` with `needs: ci`, so
a red check never produces an image the platform can pull. Nobody
clicks anything.

DB migrations are intentionally OUTSIDE this loop. See
[Migrations](#migrations).

## What runs where

| Stage             | Where                              | What                                        |
| ----------------- | ---------------------------------- | ------------------------------------------- |
| Edit + commit     | Local machine (kit hooks)          | LOC / print-debug / TODO gate, trailer gate |
| Pre-push          | Local machine (git hook)           | structural guards (+ ruff, pyright, pytest in the local-heavy model) |
| CI                | GitHub Actions, on push to main    | lint, format check, types, migration drift, migrate + tests on ephemeral Postgres, image build |
| Prod deploy gate  | `needs: ci` in the workflow        | the deploy job cannot start without a green `ci` job for the same SHA |
| Prod deploy       | GitHub Actions + platform          | exact-SHA image, rolling replace behind the health check |
| Production QA     | GitHub Actions, on demand/nightly  | `pytest -m e2e` against staging or prod with the QA sandbox login (once written) |
| Migrations        | Local terminal, manual             | `scripts/migrate-prod.sh`                   |
| Error monitoring  | Sentry (or equivalent)             | Django SDK; `release` = git SHA baked into the image |

## Two verification models

Pick one and say which in AGENTS.md. The kit's hooks are the same
either way; only the pre-push hook and the CI expectations differ.

- **Local-heavy.** Pre-push runs `uv run ruff check .`, `uv run
  pyright`, and `uv run pytest -q` before the push leaves the machine.
  CI is the Linux re-run. Feedback in a minute or two; every developer
  machine needs a local Postgres.
- **CI-heavy (remote compute).** The pre-push hook stays structural
  (LOC, print-debug, TODO, trailer). Nothing installs, builds, or runs
  a suite locally; the agent pushes and watches CI. Slower per push,
  zero local infrastructure, and the only model that works from a
  worktree without a `.venv`.

## Local dev

```bash
uv sync                                        # .venv from uv.lock, dev group included
cp .env.example .env                           # DATABASE_URL=postgres://.../<app>_dev
docker compose up -d postgres                  # or any local Postgres 16+
uv run python manage.py migrate
uv run python manage.py runserver              # :8000
```

The dev `DATABASE_URL` points at a local database or a per-developer
branch, never at prod. Settings refuse to start a non-production
`DJANGO_SETTINGS_MODULE` against a `DATABASE_URL` whose host matches
`<prod host pattern>` (a fail-closed check in `config/settings/base.py`).
`uv run` resolves the project environment on its own; do not source
the venv's activate script in scripts or hooks.

Type checks and tests need the settings module:
`[tool.pytest.ini_options] DJANGO_SETTINGS_MODULE = "config.settings.test"`
and `[tool.django-stubs] django_settings_module = "config.settings.test"`
in `pyproject.toml`. `pytest --reuse-db` keeps the test database
between runs; add `--create-db` after a migration change.

## Pushing changes

```bash
git add <paths>
git commit -m "what changed and why

Senior-Checklist: ambiguity=pass summary=pass concurrency=n/a regression=pass blast=green"
git push origin main
```

CI re-runs every check on Linux against a fresh Postgres. A
`cancelled` run means a later push superseded yours: your code ships
with THEIR deploy only if your SHA is an ancestor of the deployed one;
prove it with `git merge-base --is-ancestor <your-sha> <deployed-sha>`.

Watching CI from an agent session: never pipe the watcher.

```bash
gh run watch <id> --exit-status > watch.log 2>&1; echo "WATCH_EXIT=$?"
gh run view <id> --json status,conclusion
```

**CI green is not deployed.** The `deploy` job can fail after `ci`
passes (registry outage, platform quota, a health check that never
goes green). Confirm the rollout for the exact SHA:

```bash
curl -fsS https://<app host>/healthz          # returns {"sha": "<sha>", "db": "ok"}
fly releases -a <app>                          # Fly: latest release status and version
```

`/healthz` reads `GIT_SHA` from the environment; the Dockerfile sets
it from a build arg the deploy job passes. A health check that does
not report the SHA cannot tell you what is running.

The deploy job should: verify the green SHA is still the mainline tip
(or an ancestor), refuse to roll out an older SHA than the one live,
serialize parallel pushes with a concurrency group, and wait for the
platform to report the rollout complete. A `PRODUCTION_DEPLOY_HOLD`
marker file committed in a green SHA lets the workflow complete
WITHOUT deploying, as an interlock for a migration rollout; the commit
that satisfies the removal criteria deletes it.

## The ship loop

`/ship` runs: audit, commit, push, watch CI to a green conclusion (fix
forward, max 3), confirm `/healthz` reports the SHA, then (unless
`light`) run the post-deploy checks. Behavior-changing updates take
this path; docs-only diffs, emergency rollbacks, and an explicit "quick
push" do not. Money-path and migration diffs always add `/pre-push`.

## Parallel sessions (git worktrees)

As in the core doc: the session registry banners on start, the tangle
guard blocks a non-incumbent's commit/push in a shared checkout,
`/worktree` isolates, and the lineage alert catches a stranded HEAD.
Worktrees have no `.venv`; either `uv sync` once in the worktree or
stay on the CI-heavy model. Ship from a worktree with `git fetch origin
&& git rebase origin/main` then `git push origin HEAD:main`.

## Staging on demand

There is no standing staging environment (see the bottom of this doc
for why). When CI plus a local run is not enough confidence:

```bash
<stage-up command>              # deploy the working tree to <app>-staging against a staging DB
<stage-up command> --migrate    # also run pending migrations against the STAGING database
<stage-down command>            # scale the staging app to zero, drop the staging database
```

<!-- SETUP: on Fly this is a second app deployed with `fly deploy -a
<app>-staging -c fly.staging.toml`; on Railway or Render it is a
second service in the same project. The staging DATABASE_URL is a
fresh restore of the latest prod backup, or a copy-on-write branch if
your Postgres provider offers one. -->

Properties worth knowing:

- Staging shares nothing with prod by default: separate database,
  separate secrets. Whatever prod secrets you copy in (OAuth, email
  providers) make staging sends real sends.
- Rehearse every migration here with `--migrate` before running it in
  prod. The staging database is the only place to time a migration
  against production-sized tables.
- A staging app left running costs money and drifts; `<stage-down>`
  is part of the change, not cleanup for later.

## QA sweeps

This profile ships no QA pack. The deterministic sweep is a pytest
job marked `e2e` (Playwright for Python against a deployed URL, signed
in as the QA sandbox tenant) that gating CI runs against staging when
one is up and a nightly workflow runs against prod. Write it once a
staging target exists; until then `app-verifier` boots the dev server
and drives the changed URLs. Agents scout; deterministic specs gate.

## Migrations

**Migrations never run automatically.** `release_command` (Fly), the
pre-deploy command (Railway, Render), the Dockerfile `CMD`, and the
entrypoint script all stay free of `migrate`, permanently. Reasons:

- A migration that succeeds in a pre-deploy step can still leave a
  half-shipped schema if the rollout fails afterwards, and the platform
  rollback redeploys OLD code against the NEW schema.
- A bad migration on a multi-tenant DB affects every customer at once.
  It needs human supervision and a rehearsal.

To apply pending migrations to prod:

```bash
git fetch origin
git merge-base --is-ancestor origin/main HEAD   # must exit 0
scripts/migrate-prod.sh
```

The sanctioned runner (`scripts/migrate-prod.sh`) should:

1. Refuse unless `DJANGO_SETTINGS_MODULE` is the prod module AND the
   `DATABASE_URL` host matches `<prod host pattern>`. Prefer a DDL role
   that owns the tables; never replace the runtime credential with it.
2. Re-run the ancestry check itself.
3. Print `showmigrations --plan` (applied `[X]`, pending `[ ]`) and
   `migrate --plan`, then `sqlmigrate <app> <name>` for every pending
   migration, so the human reviews the actual SQL.
4. Demand a literal typed `APPLY`.
5. Take a session-level `pg_advisory_lock(<key>)` on a side connection
   for the duration, because Django holds no cross-runner lock and two
   sessions can both see the same pending list.
6. Run `migrate --no-input` and print `showmigrations` again.

Properties of Django's runner worth knowing:

- Migrations form a per-app dependency graph, not a timestamp list.
  Two branches that both mint `0007_` produce two leaf nodes;
  `makemigrations` and `migrate` refuse with "Conflicting migrations
  detected" until `makemigrations --merge` adds a merge node. CI's
  `makemigrations --check --dry-run` catches a model change with no
  migration; CI's `migrate` on the ephemeral database catches the
  conflict.
- On Postgres each migration is one transaction (DDL plus its
  `django_migrations` row) unless the class sets `atomic = False`. A
  failed run leaves earlier migrations applied and the failed one
  rolled back. Read the error, fix forward.
- `RunPython` needs a `reverse_code` (or `RunPython.noop`) or the
  migration cannot be unapplied anywhere, including the developer
  database that made the mistake. Data migrations use
  `apps.get_model()`, never a model import; large backfills belong in
  a management command, not a migration that holds a transaction open.
- Squash with `squashmigrations <app> <start> <end>` only after every
  environment (prod, staging, every developer database) is past the
  range; delete the originals in a later commit. `elidable=True`
  `RunPython` operations drop out of the squash.

**Always migrate BEFORE** the deploy that depends on the schema.
Additive in one deploy, destructive in a follow-up after the code
stops referencing the column. Rehearse on staging first.

**Migrations are forward-only in prod.** Never `migrate <app>
<previous>` against the prod database. Undo with a new forward
migration. The additive-first rule is what makes an image rollback
safe: old code runs fine against a schema that has one extra column.

If a migration fails, **stop**. Inspect `showmigrations` and the
schema. Point-in-time restore only for confirmed persisted corruption;
a blind restore discards unrelated writes made after the snapshot.

## Manual setup the platform needs

These live outside the repo. Do them once when standing up a new
environment.

### Platform (Fly.io, Railway, or Render)

1. Create the app or service and the Postgres instance; set
   `DATABASE_URL`, `SECRET_KEY`, `ALLOWED_HOSTS`, `DJANGO_SETTINGS_MODULE`,
   and the error reporter DSN as platform secrets.
2. Health check on `/healthz`; rolling strategy; leave the pre-deploy
   or release command EMPTY.
3. If the platform's GitHub integration would deploy on push, turn it
   off (or set it to wait for checks) so the workflow's deploy job is
   the only path to prod.
4. `python manage.py check --deploy` passes against the prod settings
   module before the first rollout.

### Error reporter

1. Create the project (Django platform); copy the DSN to the platform
   secrets; `release` = `GIT_SHA`.
2. Alert rule: error rate > 1% for 5 min to your on-call channel.

### Postgres

1. Confirm backups exist and point-in-time restore retention is at
   least 7 days. Fly's original Postgres app is self-managed: backups
   are yours to schedule.
2. Test a restore once before launch. A backup you have never
   restored is not a backup.

### GitHub

1. Repository secrets: the platform token (`FLY_API_TOKEN`,
   `RAILWAY_TOKEN`, or the Render deploy hook URL) and the registry
   credentials if you push the image yourself. Sent only to the
   platform API, never logged.
2. No branch protection if you push to main; the safety lives in CI
   and the `needs: ci` gate.

## On-call basics

When prod breaks:

1. Redeploy the previous image (fast lever): `fly deploy --image
   <previous image ref>` on Fly, or the dashboard rollback on Railway
   and Render. Skip this only when the release's migration notes mark
   it fix-forward-only.
2. Check the error reporter for the trace.
3. Check `pg_stat_activity` and the slow-query log for a lock or a
   missing index.
4. If a migration is the cause: write the forward fix migration, run
   it through the sanctioned runner, deploy. PITR-restore to a fresh
   database, verify, and swap `DATABASE_URL` only for confirmed data
   corruption.

## Things this workflow deliberately does NOT have

- **Pull requests / branch protection.** Push straight to main; safety
  lives in the kit's gates, CI, and the `needs: ci` deploy gate.
  (Switch to PRs by deleting this line and editing the TL;DR.)
- **Separate standing staging.** Staging on demand covers the scary
  changes without a second environment to keep patched.
- **Feature flags** beyond a per-tenant settings object. Revisit when
  traffic patterns justify gating.
- **A task queue** until a job needs retries or runs longer than a
  request. `transaction.on_commit` plus a management command on a
  schedule covers the first year of most products.
- **Auto-migration on deploy.** Permanently off. See
  [Migrations](#migrations).
