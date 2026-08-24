---
paths:
  - "**/scripts/**"
---

<!-- SETUP (python-fastapi-postgres): conventions for ad-hoc operational
scripts in a uv project. Replaces the core `scripts.md` when installed. -->

# Scripts

Ad-hoc operational scripts. Run them with
`uv run python scripts/<name>.py [flags]` so they see the project
environment, the shared engine, and the services. `scripts/migrate-prod.sh`
is the one shell script here and the one thing that targets prod on
purpose (see `WORKFLOW.md`).

## Naming conventions (prefix tells you the intent)

| Prefix         | Purpose                                          | Writes? |
| -------------- | ------------------------------------------------ | ------- |
| `apply-*`      | One-shot DDL or data applier                     | yes     |
| `backfill-*`   | Data backfill, usually after a schema change     | yes     |
| `reupload-*`   | Re-emit data to an external store                | yes     |
| `seed-*`       | Populate dev, e2e, or QA fixtures                | yes     |
| `gen-*`        | Generate previews or fixtures into local files   | no      |
| `check-*`      | Sanity check, prints a summary, exits clean      | no      |
| `diag-*`       | Investigate a specific bug or anomaly            | no      |
| `verify-*`     | Assert an invariant; non-zero exit on failure    | no      |
| `smoke-test-*` | Post-deploy live check; passes on green prod     | mostly no |

Hyphens in the filename are fine because scripts run as files, not as
importable modules. Anything worth importing moves into `app/`.

## Conventions

- **Module docstring at the top.** Purpose, re-run safety, accepted
  flags, and safety bounds. `argparse` is the flag parser; the
  docstring is its `description`.
- **Refuse prod by default.** Writing scripts call
  `assert_non_prod_database()` from `app/db/guard.py` first. It
  compares the `DATABASE_URL` host against the prod allowlist and exits
  unless `ALLOW_PROD_WRITES=1` is set on purpose for this run.
- **Dry-run by default.** `--apply` is a `store_true` flag that defaults
  to False; without it the script prints what it WOULD change and
  exits 0. Document it in the docstring.
- **Reuse the shared engine.** Import the session factory from
  `app.db.session`. Do not build a new engine or pool; do not read
  `DATABASE_URL` yourself.
- **Progress logging.** For any loop over more than 100 records, print
  a progress line per 100 rows so operators can see it is alive.
- **Explicit env for children.** `subprocess.run(cmd, env=os.environ)`
  or `env={**os.environ}` hands the child every secret the parent
  holds. Pass an allowlist, a list argv, and `check=True`:

  ```python
  env = {k: os.environ[k] for k in ("PATH", "HOME", "DATABASE_URL") if k in os.environ}
  subprocess.run(["pg_dump", "--schema-only", url], env=env, check=True)
  ```

- **Never `| tail` or `| head` a check.** The pipeline's exit code is
  the last command's; a red check reads as green. Redirect to a file
  and echo `$?`: `uv run pytest -q > test.log 2>&1; echo "EXIT=$?"`.
- **A detector proves itself first.** Before trusting a zero-hit scan,
  feed it an input that MUST match. An empty result and a crashed
  script look identical through a pipe.
- **`print()` is fine here.** Stdout is the product of a script; the
  ruff config exempts `scripts/**` from `T20`, and the pre-commit hook
  exempts the directory.

## When to promote a script

If a script gets used more than 3 times, promote it:

- One-shot DDL becomes an Alembic revision.
- A repeated check becomes a `tests/` module pytest collects.
- A repeated diagnostic becomes a slash command or an admin-guarded
  route.
