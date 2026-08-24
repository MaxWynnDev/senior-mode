<!-- SETUP (rust-service): conventions for operational tools. Scope this
rule by adding frontmatter at the top of the file (where the file lives
depends on the agent adapter):

---
paths:
  - "**/scripts/**"
  - "**/src/bin/**"
---

Replaces the core `scripts.md` when installed; keep one. -->

# Scripts and operational binaries

Two homes, chosen by what the tool needs:

- `src/bin/<name>.rs`: anything that touches the crate's types,
  services, or the database. It gets the same compile-time checked
  `query!` macros and the same pool constructor as the service. Run
  with `cargo run --bin <name> -- <flags>`. It ships in the image only
  if the Dockerfile copies it.
- `scripts/*.sh`: orchestration around other tools (`migrate-prod.sh`,
  `stage-up.sh`, CI helpers). `set -euo pipefail` on line 2. No
  business logic in shell.

## Naming (the prefix tells you the intent)

| Prefix         | Purpose                                          | Writes? |
| -------------- | ------------------------------------------------ | ------- |
| `apply-*`      | One-shot DDL or data applier                     | yes     |
| `backfill-*`   | Data backfill, usually after a schema change     | yes     |
| `seed-*`       | Populate dev, test, or QA fixtures               | yes     |
| `gen-*`        | Generate fixtures or previews into local files   | no      |
| `check-*`      | Sanity check, prints a summary, exits clean      | no      |
| `diag-*`       | Investigate a specific bug or anomaly            | no      |
| `verify-*`     | Assert an invariant; non-zero exit on failure    | no      |
| `smoke-test-*` | Post-deploy live check; passes on green prod     | mostly no |

## Conventions

- **Doc header at the top.** `//!` in a bin, `#` in shell: purpose,
  re-run safety, flags, and safety bounds.
- **Refuse prod by default.** Every writing bin calls the shared
  `db::assert_non_prod(&url)` (host-pattern check) before connecting.
  Opt out with `ALLOW_PROD=1`, which prints a banner naming the host.
- **Dry-run by default.** A `clap` `--apply` flag writes. Without it,
  print the count of rows that WOULD change and exit 0.
- **Reuse the shared pool.** `db::connect()` with the same pool size,
  statement timeout, and prod guard. Do not build a `PgPoolOptions` in
  a bin.
- **Progress logging.** A line per 100 rows in any loop; `println!` is
  fine here, stdout is the product. Commit per batch, not per run, so
  an interrupted backfill resumes instead of restarting.
- **Ctrl-C finishes the batch.** `tokio::signal::ctrl_c()` sets a flag;
  the loop checks it between batches.
- **Explicit env for children.** `std::process::Command` inherits the
  whole parent environment by default, every secret included. Use
  `Command::new(bin).env_clear().env("PATH", path).env("DATABASE_URL",
  url)` with an explicit allowlist.
- **Never `| tail` a check.** A pipeline's exit code is the last
  command's; a red `cargo test` reads as green. Redirect to a file and
  echo `$?`:

  ```bash
  cargo test > test.log 2>&1; echo "EXIT=$?"
  ```

- **A detector proves itself first.** Before trusting a zero-hit scan,
  feed it an input that MUST match. An empty result and a crashed tool
  look identical through a pipe.
- **Release profile for big backfills.** `cargo run --release --bin`
  when the loop is CPU-bound; the debug profile is an order of
  magnitude slower and will look like a hang.

## Promote after three uses

- One-shot DDL becomes a file under `migrations/`.
- A repeated check becomes a test under `tests/` that `cargo test`
  actually runs.
- A repeated diagnostic becomes a slash command or an admin-guarded
  route.
