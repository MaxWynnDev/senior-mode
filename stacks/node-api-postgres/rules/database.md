---
paths:
  - "**/db/**"
  - "**/drizzle/**"
  - "**/prisma/**"
  - "**/migrations/**"
---

<!-- SETUP (node-api-postgres: Drizzle ORM over Postgres, Prisma notes
inline, Kysely follows the Drizzle shape): adapt the helper names and
commands, delete the ORM you do not use. Replaces the core
`data-layer.md` when installed; keep one. -->

# Database

Postgres through one shared client: `src/db/index.ts` exports `db` (and
the `pool`) built from one `pg.Pool` or `postgres` connection with `max`
sized to the platform's connection budget. Nothing else opens one.

## Schema files

- Drizzle: `src/db/schema/*.ts`, one file per domain, `index.ts`
  barrel. Prisma: `prisma/schema.prisma`, split into `prisma/schema/`
  past ~400 lines.
- Every tenant-owned table has `tenant_id NOT NULL` and an index that
  leads with it. FKs use `onDelete: "cascade"` unless documented.
- Timestamps are `timestamptz` with `defaultNow()`; ids default in the
  database (`gen_random_uuid()`), not in application code, so a raw
  INSERT cannot forget them. Raw inserts supply everything else the ORM
  normally supplies.

## Migrations

- Prod runs ONLY through the sanctioned runner (`pnpm db:migrate:prod`,
  `scripts/migrate-prod.ts`): verifies the host, prints the pending
  entries, demands a typed `APPLY`. Never `drizzle-kit migrate` or
  `prisma migrate deploy` pointed at prod by hand; never in the
  Dockerfile, the image entrypoint, or a platform release command.
- Additive first: new column, index, table. The same image must work
  against the old and the new schema. Drops ship in a follow-up after
  the code stops referencing the column.
- Drizzle: `pnpm drizzle-kit generate` writes the SQL AND
  `meta/_journal.json`; both land in the same commit, and the entry's
  `when` must be newer than the last row in `drizzle.__drizzle_migrations`.
  The migrator applies only entries newer than that watermark, so a
  stale entry from a parallel session is skipped silently. `pnpm
  drizzle-kit check` catches journal/snapshot races; `push` is dev-only.
- Prisma: `pnpm prisma migrate dev` locally (it can reset the database;
  dev-only), `migrate deploy` inside the runner. An applied file is
  immutable: `_prisma_migrations` stores its checksum. Fix forward.
- Inspect generated SQL. Generators add DROPs for anything they think is
  orphaned. `CREATE INDEX CONCURRENTLY` cannot run inside a transaction;
  give it its own migration and say so in a comment.
- If the app connects as a restricted role, migrations run as the owner
  and grant every object they create to the app role in the same file.

## Queries

- Every query over tenant-owned data filters by `tenantId` from the auth
  context: `where(and(eq(things.tenantId, ctx.tenantId), ...))` or
  `where: { tenantId: ctx.tenantId, ... }`. A `findById` without the
  tenant predicate is a bug even when the id is a UUID.
- If Postgres RLS is on, go through `withTenant(ctx, (tx) => ...)`, which
  sets the session GUC inside a transaction. An unwrapped query returns
  zero rows silently; keep the app-level filter as well. `RETURNING` is
  checked against the SELECT policy too.
- `sql\`...\`` is an unchecked cast. `= ANY(${jsArray})` serializes the
  array as one value and matches nothing; use `inArray(col, values)`
  (Drizzle) or the `in` filter / `Prisma.join` (Prisma). A `jsonb`
  column takes `${JSON.stringify(v)}::jsonb`.
- Money is integer minor units in `integer` or `bigint` columns, never
  `numeric` read into a JS `number`, never `real`. Sum in SQL with
  `sum(...)::bigint` and parse the string explicitly; the driver returns
  `bigint` and `numeric` as strings.
- Multi-table writes are one transaction: `db.transaction(async (tx) =>
  ...)` or `prisma.$transaction(async (tx) => ...)`, and every service
  in the chain receives `tx`. A write inside a swallowing catch is a
  defect: it will not 500, it will quietly not write.
- Retried writes (webhooks, client retries, cron re-fires) are
  idempotent: a unique constraint on the idempotency key plus
  `onConflictDoNothing()` / `ON CONFLICT DO NOTHING`, and the response
  is the stored result, not a second execution.

## Schema drift (the silent-drop bug class)

When older tenants lack an attribute newer code expects to write, the
write silently drops. Adding to a canonical seed requires all of: (1)
the seed change, (2) a migration that idempotently inserts it into every
existing tenant, (3) the self-healing service lazy-creating on first
write, (4) a contract test locking the helper's list to the seed.
