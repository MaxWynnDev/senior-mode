# Stack profile: django-postgres

A Python profile for a web app or JSON API on Django, packaged as an
overlay. Install with `bash install.sh --profile django-postgres <repo>`,
or copy the pieces by hand. Nothing here is required by the core kit;
a project on another stack skips this folder entirely (see
`../../STACK.md`).

## What it assumes

- Python 3.12+, Django 5.x, settings split per environment
  (`config/settings/{base,dev,prod}.py`) or one settings module driven
  by env vars; `DATABASE_URL` either way.
- Postgres through psycopg 3, Django's own migrations (per app,
  numbered, dependency graph), no second migration tool.
- Auth from `django.contrib.auth` sessions, plus API keys or tokens
  resolved by ONE authentication class or middleware. Permissions are
  fine-grained (`request.user.has_perm` or a `require_permission`
  helper), not mere login.
- JSON APIs through Django REST Framework or Django Ninja. Server
  rendered templates (optionally HTMX) for UI; the core `ui.md` rule
  stays in force for them.
- uv for dependencies (`uv.lock` committed; `pip` from an exported
  requirements file is the fallback), ruff for lint and format, pyright
  with django-stubs (mypy plus the django-stubs plugin is the
  alternative), pytest with pytest-django.
- One Docker image, gunicorn serving WSGI (uvicorn only if you have
  async views or Channels), WhiteNoise for static files, deployed to
  Fly.io, Railway, or Render. GitHub Actions CI; a CI-gated deploy; a
  rolling replace behind a health check.
- Layout: `config/` for the project package, `apps/<domain>/` with
  `models.py`, `services.py`, `selectors.py`, `api/` (views and
  serializers, or a Ninja router), `migrations/`, and
  `management/commands/`. A flat single-app layout works with the same
  rule globs.

## What's in the overlay

| Path | Installs as | Purpose |
|---|---|---|
| `rules/api-routes.md` | path-scoped rule (location depends on the agent adapter) | views, DRF viewsets, Ninja routers: one auth resolver, serializers at the boundary, tenant from membership, no writes in GET, `select_related` on lists |
| `rules/database.md` | path-scoped rule (location depends on the agent adapter) | models, additive migrations, `makemigrations --check`, `RunPython` reversibility, raw SQL as a cast, integer money, `atomic()` and `select_for_update()` |
| `rules/services.md` | path-scoped rule (location depends on the agent adapter) | service modules: tenant plus actor arguments, explicit `atomic`/`using`, sensitive fields filtered before logs or an LLM |
| `rules/scripts.md` | path-scoped rule (location depends on the agent adapter) | management commands vs ad-hoc scripts, prefixes, `--apply`, refuse prod, env allowlists, no piped checks |
| `WORKFLOW.md` | repo root | the concrete pipeline (replaces the core template) |

The profile's rules REPLACE the core's `api-boundary.md`,
`data-layer.md`, `services.md`, and `scripts.md`. The kickoff asks you
to keep one of each pair so they never disagree. The core `ui.md` is
kept as is.

## Platform notes worth knowing (as of mid-2026)

- Django 5.2 is the current LTS. Useful 5.x additions: `db_default`
  and `GeneratedField` (5.0), `LoginRequiredMiddleware` (5.1),
  composite primary keys (5.2). psycopg 3 has been the supported
  driver since 4.2; prefer it over psycopg2 for new projects.
- `makemigrations --check` exits non-zero when a model change has no
  migration and, since 4.2, writes nothing. `migrate --check` exits
  non-zero when a migration is unapplied. Both are cheap CI gates.
- On Postgres every migration runs in its own transaction and the
  `django_migrations` row commits with the DDL, so a failed run stops
  at the failed migration with everything before it applied.
  `CREATE INDEX CONCURRENTLY` needs `atomic = False` on the migration
  and `AddIndexConcurrently` from `django.contrib.postgres.operations`.
- uv: `uv sync --locked` in CI and Docker refuses to run if `uv.lock`
  is stale; `uv run <cmd>` needs no activated venv; the official
  `ghcr.io/astral-sh/uv` images provide the binary for a multi-stage
  build.
- pytest-django: `--reuse-db` keeps the test database between runs;
  `django_assert_num_queries` locks a list endpoint's query count.
- Fly.io runs `[deploy] release_command` in a temporary machine before
  each rollout; Railway and Render offer an equivalent pre-deploy
  command. This profile leaves all three EMPTY and migrates through
  the sanctioned runner (see `WORKFLOW.md`). All three platforms can
  redeploy a previous image from the CLI or dashboard; that is the
  rollback lever.
- gunicorn defaults to sync workers and a 30 second request timeout.
  Size `--workers` to the machine (2 per CPU plus one is the usual
  start) and put long work in a job, not a request.
- ruff's `DJ` rule set (flake8-django) catches `null=True` on text
  fields, missing `__str__`, and model attribute ordering. Enable it.

## Install by hand

1. Rules: copy `rules/*.md` into the adapter's path-scoped rule
   location (`.senior-mode/rules/`, which the installer wires into each
   agent adapter's native rule directory),
   deleting the core rules they replace.
2. Docs: `WORKFLOW.md` to the repo root; fill every `<...>` and
   `<!-- SETUP -->` marker.
3. The sanctioned migration runner: write `scripts/migrate-prod.sh`
   to the contract in `WORKFLOW.md` (host check, plan, typed
   confirmation, migrate) and point `profile.json`'s `migrate_prod` at
   it.
4. CI: a workflow that runs `uv sync --locked`, `ruff check`,
   `ruff format --check`, `pyright`, `makemigrations --check
   --dry-run`, `migrate` and `pytest` against a Postgres service
   container, then `docker build`; a deploy job gated on it.
5. `pyproject.toml`: `[tool.pytest.ini_options]` with
   `DJANGO_SETTINGS_MODULE`, `[tool.django-stubs]` with
   `django_settings_module`, and the ruff `DJ` and `I` rule sets.

## What to adapt if you use FastAPI or Flask

- FastAPI: migrations move to Alembic (`alembic revision
  --autogenerate` to mint, `alembic check` as the CI drift gate);
  views become routers with the auth resolver as a `Depends`. Keep
  uv, ruff, pyright, pytest, the image, and the forward-only rule.
- Flask: Alembic through Flask-Migrate for the same two commands;
  blueprints with a `before_request` auth hook replace the DRF
  permission class, and a SQLAlchemy session scope replaces
  `transaction.atomic()`.
