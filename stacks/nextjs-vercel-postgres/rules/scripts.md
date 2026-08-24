---
paths:
  - "**/scripts/**"
---

<!-- SETUP (reference stack): conventions for ad-hoc operational scripts in
a pnpm/Node project. Replaces the core `scripts.md` when installed. -->

# Scripts

Ad-hoc operational scripts. Run `.ts` scripts through `tsx`
(`pnpm exec tsx scripts/<name>.ts`) for typed access to the ORM and
services; `.mjs` scripts are plain Node for bounded checks with
hand-rolled env loading.

## Naming conventions (prefix tells you the intent)

| Prefix         | Purpose                                          | Reads only? |
| -------------- | ------------------------------------------------ | ----------- |
| `apply-*`      | One-shot migration or DDL applier                | No          |
| `backfill-*`   | Data backfill, usually after a schema change     | No          |
| `reupload-*`   | Re-emit data to an external store                | No          |
| `seed-*`       | Populate dev, e2e, or QA fixtures                | No          |
| `gen-*`        | Generate previews or fixtures into local files   | Read-only   |
| `check-*`      | Sanity check, prints a summary, exits clean      | Read-only   |
| `diag-*`       | Investigate a specific bug or anomaly            | Read-only   |
| `verify-*`     | Assert an invariant; non-zero exit on failure    | Read-only   |
| `smoke-test-*` | Post-deploy live check; passes on green prod     | Mostly RO   |

## Conventions

- **Doc header at the top.** State purpose, re-run safety, accepted
  flags, and safety bounds in a comment block.
- **Safety check for prod data.** Destructive scripts refuse to run
  against a URL that looks like prod unless an opt-out env var is set
  (an `assertNonProdDatabase` helper).
- **Dry-run by default for destructive scripts.** Require an explicit
  `--apply` flag to write. Document it in the header.
- **Reuse the shared DB client.** Import `db` from `@/db`; do not roll a
  new pool.
- **Progress logging.** For any loop over more than 100 records, emit a
  progress line per 100 rows so operators can see it is alive.
- **Explicit env for children.** `spawn(cmd, { env: { ...process.env } })`
  hands the child every secret. Pass an allowlist.
- **Never `| tail` a check.** The pipe's exit code replaces the check's.
- **`console.log` is fine here.** Stdout is the product of a script; the
  pre-commit hook exempts `scripts/`.

## When to promote a script

If a script gets used more than 3 times, promote it:

- One-shot DDL becomes a numbered migration.
- A repeated check becomes a test the runner imports.
- A repeated diagnostic becomes a slash command or an admin-guarded
  route.
