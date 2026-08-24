# Stack profile: python-fastapi-postgres

A Python API service packaged as an overlay. Install with
`bash install.sh --profile python-fastapi-postgres <repo>`, or copy the
pieces by hand. Nothing here is required by the core kit; a project on
another stack skips this folder entirely (see `../../STACK.md`).

## What it assumes

- Python 3.12+ and FastAPI. Pydantic v2 models at the request boundary,
  `pydantic-settings` for configuration, routers per domain under
  `app/api/`, one dependency module (`app/api/deps.py`) that resolves
  auth, the session, and permissions.
- SQLAlchemy 2.x (`Mapped[]` / `mapped_column`, `DeclarativeBase`),
  async through `asyncpg` or `psycopg` 3, or sync through `psycopg` 3.
  Alembic owns the migration graph. Postgres in every environment,
  including tests (a service container in CI, never SQLite).
- uv for packages and the lockfile (`uv.lock`); `uv run` for every
  command so nobody activates a virtualenv by hand. pip is a fallback
  through `uv export`.
- ruff for lint and format, pyright (or mypy) strict, pytest with
  `pytest-asyncio` and `httpx.ASGITransport` for route tests.
- A Docker image built in CI and deployed to Fly.io, Railway, or Render.
  GitHub Actions is the only path to production; migrations are outside
  the deploy loop.
- A single-app layout (`app/` package, `alembic/` beside it). A
  `src/<pkg>/` layout works with the path candidates in the rules.

## What's in the overlay

| Path | Installs as | Purpose |
|---|---|---|
| `rules/api-routes.md` | path-scoped rule (location depends on the agent adapter) | the route contract with FastAPI `Depends`, Pydantic at the boundary, router per domain; scoped to `**/app/api/**` |
| `rules/database.md` | path-scoped rule (location depends on the agent adapter) | SQLAlchemy models and sessions, Alembic autogenerate pitfalls, raw SQL casts, tenant filters; scoped to models, `db/`, `alembic/` |
| `rules/services.md` | path-scoped rule (location depends on the agent adapter) | the business-logic layer: explicit session parameter, no framework imports, async pitfalls; scoped to `**/services/**` |
| `rules/scripts.md` | path-scoped rule (location depends on the agent adapter) | operational scripts: prefixes, `--apply`, refuse prod, subprocess env allowlist; scoped to `**/scripts/**` |
| `WORKFLOW.md` | repo root | the concrete pipeline (replaces the core template) |

The profile's rules REPLACE the core's `api-boundary.md`,
`data-layer.md`, `services.md`, and `scripts.md`. The kickoff asks you
to keep one of each pair so they never disagree. The core `ui.md` has no
counterpart here; delete it for an API-only service, keep it if the app
serves templates.

This profile ships no slash commands and no QA pack. `/stage` and
`/qa-sweep` from the reference profile can be rebuilt on a seeded
ephemeral Postgres plus a second app on your platform; see "Staging on
demand" in `WORKFLOW.md`.

## Platform notes worth knowing (as of mid-2026)

- `uv sync --locked` fails when `uv.lock` is out of date, which is the
  behavior CI wants. `uv run <cmd>` uses the project environment without
  activation. Official images exist at
  `ghcr.io/astral-sh/uv:python3.12-bookworm-slim`; set
  `UV_COMPILE_BYTECODE=1` in the Dockerfile and install dependencies in
  a layer before copying the source so the cache survives code edits.
- Python 3.12 deprecates `datetime.utcnow()`. Use
  `datetime.now(UTC)`; the ruff `DTZ` rules flag the naive forms.
- Alembic: `alembic check` (1.9+) exits non-zero when the models and
  the migration graph disagree, and needs a live database at `head` to
  compare against. `compare_type` defaults to on since 1.12. Autogenerate
  does not compare `server_default` unless you turn it on, and never
  emits `ALTER TYPE ... ADD VALUE` for enums.
- Fly.io: `fly deploy` builds the Dockerfile and rolls machines one at a
  time by default. There is no rollback command; the lever is
  `fly releases --image` to find the previous image, then
  `fly deploy --image <ref>`. Rolling back does not restore an older
  `fly.toml` or secrets. `[deploy] release_command` in `fly.toml` runs
  before the new version goes live; keep `alembic upgrade` out of it.
  Fly's classic `fly postgres` app is self-managed by design; pick a
  managed Postgres unless you want to own backups and failover.
- Railway and Render both build a root `Dockerfile` automatically and
  both offer a pre-deploy command (`railway.json` / `railway.toml`,
  `render.yaml` `preDeployCommand`). Same rule: no migrations there.
  Both can wait for GitHub checks before auto-deploying; turn that on,
  or turn auto-deploy off and let the CI job deploy. Rollback on both
  is a redeploy of a prior deployment from the dashboard.
- GitHub Actions: `astral-sh/setup-uv` (with `enable-cache: true`) and
  `superfly/flyctl-actions/setup-flyctl` are the maintained actions. A
  deploy token from `fly tokens create deploy` goes in the
  `FLY_API_TOKEN` secret and is sent only to the Fly API.

## Install by hand

1. Rules: copy `rules/*.md` into your agent adapter's rules location
   and keep the `paths:` frontmatter; delete the four core rules they
   replace.
2. Docs: `WORKFLOW.md` to the repo root.
3. The migration runner: write `scripts/migrate-prod.sh` with the
   properties listed in `WORKFLOW.md` (host check, pending list, typed
   confirmation, one-head check). Have `alembic/env.py` read
   `DATABASE_URL` from the environment instead of `alembic.ini`.
4. `pyproject.toml`: register the `e2e` pytest marker; enable ruff
   `T20` (print) and `DTZ` (naive datetime) rules with a
   `per-file-ignores` entry that exempts `scripts/**` from `T20`; set
   pyright to `strict` for `app/`.
5. CI: a Postgres service container, `uv sync --locked`, ruff, pyright,
   pytest, `alembic upgrade head` then `alembic check`, the one-head
   check, `docker build`, and a deploy job gated on all of it.

## What to adapt if you use Django or Flask instead

- **Django:** the auth resolver is middleware plus `request.user`, and
  `manage.py migrate` replaces Alembic. Keep the runner wrapper; the
  "one head" check becomes `makemigrations --check` plus a
  merge-migration scan, and `rules/api-routes.md` becomes a DRF view rule.
- **Flask:** `Depends` becomes a `before_request` hook or a decorator
  that loads the auth context onto `g`, and Pydantic validation is a
  decorator you write once. Alembic and the database rule carry over
  unchanged (Flask-Migrate wraps the same commands).
