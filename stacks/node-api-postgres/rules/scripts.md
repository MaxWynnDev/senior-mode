---
paths:
  - "**/scripts/**"
---

<!-- SETUP (node-api-postgres): conventions for ad-hoc operational
scripts in a pnpm/Node project. Replaces the core `scripts.md` when
installed. -->

# Scripts

Ad-hoc operational scripts under `scripts/*.ts`, run with
`pnpm exec tsx scripts/<name>.ts` so they get the shared `db`, the
services, and the app's path aliases. No `.js` copies, no second build.
Env loads once through the shared `loadEnv()` (or Node's
`--env-file=.env`), never a `dotenv.config()` per script.

## Naming (the prefix tells you the intent)

| Prefix         | Purpose                                          | Writes?    |
| -------------- | ------------------------------------------------ | ---------- |
| `apply-*`      | One-shot migration or DDL applier                | yes        |
| `backfill-*`   | Data backfill, usually after a schema change     | yes        |
| `seed-*`       | Populate dev, test, or QA fixtures               | yes        |
| `migrate-*`    | The sanctioned migration runner                  | yes, gated |
| `gen-*`        | Generate fixtures or previews into local files   | no         |
| `check-*`      | Sanity check, prints a summary, exits clean      | no         |
| `diag-*`       | Investigate a specific bug or anomaly            | no         |
| `verify-*`     | Assert an invariant; non-zero exit on failure    | no         |
| `smoke-test-*` | Post-deploy live check; passes on green prod     | mostly no  |

## Skeleton

```ts
/**
 * backfill-thing-slugs: fills things.slug for rows created before <date>.
 * Safe to re-run (skips rows that have a slug). Flags: --apply (writes),
 * --tenant <id> (one tenant), --limit <n> (default 500). Refuses a prod
 * DATABASE_URL unless ALLOW_PROD_SCRIPTS=1.
 */
import { parseArgs } from "node:util";
import { db, pool } from "@/db";
import { assertNonProdDatabase } from "@/lib/env";

const { values } = parseArgs({
  options: { apply: { type: "boolean" }, tenant: { type: "string" }, limit: { type: "string" } },
});
assertNonProdDatabase();                                 // throws unless ALLOW_PROD_SCRIPTS=1
if (!values.apply) console.log("DRY RUN (pass --apply to write)");
// ... batched loop, progress line per 100 rows ...
await pool.end();                                        // or prisma.$disconnect()
```

## Conventions

- **Doc header at the top.** Purpose, re-run safety, flags, bounds.
- **Refuse prod by default.** `assertNonProdDatabase()` matches the
  `DATABASE_URL` host against the prod pattern and throws unless
  `ALLOW_PROD_SCRIPTS=1` is set for that one invocation.
- **Dry-run by default.** `--apply` writes; the dry run prints the rows
  it would touch and the count.
- **Reuse the shared DB client.** Import `db` from `@/db`; do not roll a
  new pool. End the pool at exit so the process does not hang.
- **Progress logging.** A line per 100 rows in any loop over 100+ rows.
  Batch with `inArray` on chunks of 500, not one query per row.
- **Explicit env for children.** `spawn(cmd, args, { env: { PATH:
  process.env.PATH, DATABASE_URL: url } })`. Never `{ ...process.env }`:
  it hands the child every secret the parent holds.
- **Never `| tail` or `| head` a check.** The pipeline's exit code is the
  last command's; a red check reads as green. `pnpm test > test.log
  2>&1; echo "EXIT=$?"`.
- **A detector proves itself first.** Feed a zero-hit scan an input that
  MUST match before trusting the zero.
- **Bounded.** `--limit` defaults small; the operator raises it on
  purpose.
- **`console.log` is fine here.** Stdout is the product of a script; the
  pre-commit hook exempts `scripts/`.

## Promote after three uses

- One-shot DDL becomes a numbered migration.
- A repeated check becomes a vitest test the runner imports.
- A repeated diagnostic becomes an admin-guarded route.
