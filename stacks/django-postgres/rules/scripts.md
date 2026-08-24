---
paths:
  - "**/scripts/**"
  - "**/management/commands/**"
---

<!-- SETUP (django-postgres): the `paths:` frontmatter above scopes this
rule; adapters that do not read frontmatter map the same globs in their
own config. Replaces the core `scripts.md` when installed. -->

# Scripts and management commands

Two homes. A management command
(`apps/<domain>/management/commands/<prefix>_<name>.py`, run as
`uv run python manage.py <prefix>_<name>`) gets settings, the ORM
connection, argument parsing, and `CommandError` for free; it is the
default. A file under `scripts/` (run as `uv run python scripts/<name>.py`)
is for work that must not import Django (image build helpers, release
tooling) or that wraps `manage.py` itself, like `migrate-prod.sh`.

## Naming (the prefix tells you the intent)

| Prefix          | Purpose                                          | Writes? |
| --------------- | ------------------------------------------------ | ------- |
| `apply_*`       | One-shot DDL or data applier                     | yes     |
| `backfill_*`    | Data backfill, usually after a schema change     | yes     |
| `seed_*`        | Populate dev, e2e, or QA fixtures                | yes     |
| `gen_*`         | Generate previews or fixtures into local files   | no      |
| `check_*`       | Sanity check, prints a summary, exits clean      | no      |
| `diag_*`        | Investigate a specific bug or anomaly            | no      |
| `verify_*`      | Assert an invariant; `CommandError` on failure   | no      |
| `smoke_test_*`  | Post-deploy live check; passes on green prod     | mostly no |

## Conventions

- **Doc header at the top.** Module docstring plus the command's
  `help`: purpose, re-run safety, accepted flags, safety bounds.
- **Dry-run by default.** Writers declare `--apply` (`store_true`) in
  `add_arguments`; without it they print what they would change and
  the row count, then exit 0.
- **Refuse prod by default.** Writers read
  `connections["default"].settings_dict["HOST"]` and raise
  `CommandError` when it matches `<prod host pattern>` unless
  `ALLOW_PROD_SCRIPTS=1` is set. Read-only commands may run anywhere.
- **Reuse the ORM connection.** No `psycopg.connect()` with a copied
  URL; use the models or `connection.cursor()`.
- **Batches and progress.** Iterate with `.iterator(chunk_size=1000)`
  or `Paginator`; wrap each batch in its own `transaction.atomic()`;
  emit a progress line per 100 rows through `self.stdout.write` so
  an operator can see it is alive. `print` is fine under `scripts/`.
- **Explicit env for children.** `subprocess.run(cmd, env=os.environ)`
  hands the child every secret. Build the env from an allowlist:
  `env={"PATH": os.environ["PATH"], "DATABASE_URL": url}`.
- **Never `| tail` or `| head` a check.** The pipe's exit code
  replaces the check's. Redirect to a file and echo `$?`, or read the
  command's own status output.
- **A detector proves itself first.** Before trusting a zero-hit
  scan, feed it an input that MUST match. An empty result and a
  crashed tool look identical through a pipe.
- **Exit codes mean something.** `verify_*` raises `CommandError` so
  CI and the ship loop can gate on it; a summary printed in green with
  exit 0 is not a verification.

## Promote after three uses

- One-shot DDL becomes a numbered migration in the owning app.
- A repeated check becomes a pytest test the runner collects.
- A repeated diagnostic becomes a slash command or an admin action
  behind `is_staff` plus the permission check.
