---
paths:
  - "lib/tasks/**"
  - "bin/**"
  - "scripts/**"
  - "db/seeds.rb"
  - "db/seeds/**"
---

<!-- SETUP (rails-postgres profile): conventions for operational scripts
in a Rails app. Replaces the core `scripts.md` when installed. -->

# Scripts

Three tools, pick by lifetime:

| Tool | Use for | Boots the app? |
|---|---|---|
| `lib/tasks/*.rake` (`task name: :environment`) | repeatable operations run more than once (backfills, checks, seeds) | yes |
| `bin/<name>` (bash or Ruby, `set -euo pipefail`) | orchestration that wraps other tools: migrate-prod, stage, smoke tests | no |
| `bin/rails runner scripts/<name>.rb` | one-offs and diagnostics with a doc header, committed or deleted | yes |

Never paste multi-line logic into a production `rails console`. Put it
in `scripts/`, run it with `runner`, and the file is the audit trail.

## Naming (the prefix tells you the intent)

| Prefix         | Purpose                                          | Writes? |
| -------------- | ------------------------------------------------ | ------- |
| `apply-*`      | One-shot DDL or data applier                     | yes     |
| `backfill-*`   | Data backfill, usually after a schema change     | yes     |
| `seed-*`       | Populate dev, e2e, or QA fixtures                | yes     |
| `gen-*`        | Generate previews or fixtures into local files   | no      |
| `check-*`      | Sanity check, prints a summary, exits clean      | no      |
| `diag-*`       | Investigate a specific bug or anomaly            | no      |
| `verify-*`     | Assert an invariant; non-zero exit on failure    | no      |
| `smoke-test-*` | Post-deploy live check; passes on green prod     | mostly no |

Rake tasks use the same words as namespaces: `rake backfill:invoice_due_on`.

## Conventions

- **Doc header at the top.** Purpose, re-run safety, accepted flags,
  and safety bounds, in a comment block.
- **Refuse prod by default.** A writing script aborts when
  `Rails.env.production?` or the database host matches the prod pattern,
  unless `ALLOW_PROD=1` is set. `RAILS_ENV=production bin/rails runner`
  on a laptop with a prod `DATABASE_URL` is a live wire; through Kamal
  it is `bin/kamal app exec --reuse "bin/rails runner scripts/x.rb"`.
- **Dry-run by default.** `--apply` (runner scripts) or `APPLY=1` (rake)
  writes; without it the script prints what it would do and the count.
- **Reuse the app's connection.** `ApplicationRecord.connection`, not a
  new `PG.connect`. Never a second connection pool.
- **Batches and progress.** `find_each(batch_size: 1000)` or
  `in_batches`, a progress line every 1000 rows (`$stdout.sync = true`),
  and a bounded loop (`in_batches(of: 1000).each_with_index` with a
  maximum), never `loop do` without an exit.
- **Explicit env for children.** `system(cmd)` and `Process.spawn(cmd)`
  hand the child every secret the parent holds. Pass an allowlist:
  `system({ "PATH" => ENV["PATH"], "DATABASE_URL" => url }, cmd,
  unsetenv_others: true)`.
- **Never `| tail` or `| head` a check.** The pipeline's exit code is
  the last command's; a red check reads as green. Redirect to a file
  and echo `$?`.
- **A detector proves itself first.** Before trusting a zero-hit scan,
  feed it an input that MUST match.
- **`puts` is fine here.** Stdout is the product. Exclude `lib/tasks/**`
  and `scripts/**` from the `Rails/Output` cop in `.rubocop.yml`; the
  print-debug hook exempts them too.
- **Seeds are idempotent.** `db/seeds.rb` uses `find_or_create_by!`;
  `db:seed` refuses production unless `ALLOW_PROD=1`.

## Promote after three uses

- One-shot DDL becomes a timestamped migration.
- A repeated check becomes a spec the runner imports.
- A repeated diagnostic becomes an admin-guarded controller action or a
  rake task with a doc header.
