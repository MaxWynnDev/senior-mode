---
paths:
  - "**/cmd/tools/**"
  - "**/scripts/**"
---

<!-- SETUP (go-service profile): conventions for operational tools and
glue scripts in a Go module. Replaces the core `scripts.md` when
installed. -->

# Scripts and tools

Two homes, chosen by whether the code touches data:

- `cmd/tools/<name>/main.go`: anything that opens the database or calls
  a service. Compiled, typed, uses the shared pool and sqlc queries.
  Run with `go run ./cmd/tools/<name> -flag ...`.
- `scripts/*.sh`: glue with no database access (the migrate wrapper,
  image tagging, CI helpers). `set -euo pipefail` at the top.

## Naming (the prefix tells you the intent)

| Prefix         | Purpose                                          | Writes? |
| -------------- | ------------------------------------------------ | ------- |
| `apply-*`      | One-shot DDL or data fix                         | yes     |
| `backfill-*`   | Data backfill, usually after a schema change     | yes     |
| `seed-*`       | Populate dev, integration, or QA fixtures        | yes     |
| `gen-*`        | Generate fixtures or previews into local files   | no      |
| `check-*`      | Sanity check, prints a summary, exits clean      | no      |
| `diag-*`       | Investigate a specific bug or anomaly            | no      |
| `verify-*`     | Assert an invariant; non-zero exit on failure    | no      |
| `smoke-test`   | Post-deploy live check; passes on green prod     | mostly no |

## Conventions

- **Doc comment at the top of `main.go`.** Purpose, re-run safety,
  accepted flags, and safety bounds, in the package comment.
- **`-apply` defaults to false.** Without it the tool prints what it
  would change and exits 0. Use the `flag` package; no positional magic.
- **Refuse prod by default.** `db.AssertNonProd(url)` unless
  `ALLOW_PROD=1` is set; even then require `-apply` and print the host
  before the first write.
- **Reuse `db.Connect(ctx)`.** No second pool, no hand-built DSN.
- **`main` is `os.Exit(run())`.** Deferred cleanup (pool close, tx
  rollback) does not run past `log.Fatal` or a direct `os.Exit`.
- **Batches by key, not offset.** `WHERE id > $1 ORDER BY id LIMIT 500`,
  one transaction per batch, a progress line per batch so operators can
  see it is alive.
- **Explicit env for children.** `exec.CommandContext(ctx, name, args...)`
  with `cmd.Env` set to an allowlist (`PATH`, `HOME`, what the child
  needs). A nil `Env` inherits all of `os.Environ()`, including
  `DATABASE_URL` and every API key the parent holds.
- **Never `| tail` or `| head` a check.** The pipeline's exit code is the
  last command's; a red check reads as green. Redirect to a file and
  echo `$?`, or read the tool's own status output.
- **A detector proves itself first.** Before trusting a zero-hit scan,
  feed it an input that MUST match. An empty result and a crashed tool
  look identical through a pipe.
- **`fmt.Println` is fine here.** Stdout is the product of a tool; the
  print-debug hook exempts `cmd/tools/` and `scripts/`.

## Promote after three uses

- One-shot DDL becomes a goose migration.
- A repeated check becomes a test that `go test ./...` runs.
- A repeated diagnostic becomes a slash command or an admin-gated
  route.
