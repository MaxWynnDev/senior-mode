<!-- SETUP: conventions for ad-hoc operational scripts. Scope it with
`paths:` frontmatter (e.g. "scripts/**", "bin/**", "tools/**"). The prefix
table and the safety rules are stack-agnostic and worth keeping. -->

# Scripts

Ad-hoc operational scripts: backfills, checks, diagnostics, seeds.

## Naming (the prefix tells you the intent)

| Prefix         | Purpose                                          | Writes? |
| -------------- | ------------------------------------------------ | ------- |
| `apply-*`      | One-shot migration or DDL applier                | yes     |
| `backfill-*`   | Data backfill, usually after a schema change     | yes     |
| `seed-*`       | Populate dev, e2e, or QA fixtures                | yes     |
| `gen-*`        | Generate previews or fixtures into local files   | no      |
| `check-*`      | Sanity check, prints a summary, exits clean      | no      |
| `diag-*`       | Investigate a specific bug or anomaly            | no      |
| `verify-*`     | Assert an invariant; non-zero exit on failure    | no      |
| `smoke-test-*` | Post-deploy live check; passes on green prod     | mostly no |

## Conventions

- **Doc header at the top.** Purpose, re-run safety, accepted flags,
  and safety bounds, in a comment block.
- **Refuse prod by default.** Destructive scripts refuse a target that
  looks like production unless an explicit opt-out variable is set.
- **Dry-run by default.** An explicit `--apply` flag writes. Document it
  in the header.
- **Reuse the shared DB client.** Do not roll a new connection pool.
- **Progress logging.** For any loop over more than 100 records, emit a
  progress line per 100 rows so operators can see it is alive.
- **Never inherit the whole environment into a child process.**
  `{...process.env}` (or the shell equivalent) hands every secret the
  parent holds to the child. Pass an explicit allowlist.
- **Do not pipe a check through `tail` or `head`.** The pipeline's exit
  code is the last command's; a red check reads as green. Redirect to a
  file and echo `$?`, or read the tool's own status output.
- **A detector proves itself first.** Before trusting a zero-hit scan,
  feed it an input that MUST match. An empty result and a crashed tool
  look identical through a pipe.

## Promote after three uses

- One-shot DDL becomes a numbered migration.
- A repeated check becomes a test the runner actually imports.
- A repeated diagnostic becomes a slash command or an admin-guarded
  route.
