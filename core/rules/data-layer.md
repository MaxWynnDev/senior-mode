<!-- SETUP: stack-neutral rule for schema, migrations, and queries. Scope it
with `paths:` frontmatter (e.g. "src/db/**", "prisma/**", "migrations/**",
"app/models/**") so it loads only when data-layer files are touched. Name
your sanctioned migration runner and tenant wrapper where the brackets are.
The reference stack profile ships a concrete Postgres + Drizzle version. -->

# Data layer

## Migrations

- Production migrations run ONLY through the sanctioned runner
  (`<your migrate:prod command>`). It verifies the target host, prints
  what it is about to apply, and demands a typed confirmation. Never in
  the build command; never the ORM's migrate CLI pointed at prod.
- Additive first. New column, index, table, constraint. The same code
  must work against the old and the new schema, because deploy and
  migration order is not guaranteed. Destructive drops ship in a
  follow-up deploy after the code stops referencing the column.
- A new migration and its journal/manifest entry land in the same
  commit, and the entry's timestamp or sequence must be newer than the
  last applied one. An orphan file or a stale watermark is silently
  skipped by journal-driven runners.
- Inspect generated SQL before committing. Generators add DROP
  statements for anything they think is orphaned.
- `CREATE OR REPLACE` replaces the LATEST prior body, not the one you
  remember. Diff against it.

## Queries

- Every query that returns tenant-owned data filters by the tenant key,
  or goes through the tenant wrapper (`<withTenant>`) if the database
  enforces row isolation. Skipping the wrapper under enforcement returns
  zero rows silently: the query does not error, it lies.
- A raw SQL template is an unchecked cast. Interpolating a language
  array or object where the database expects a scalar or a typed array
  compiles, runs, and matches nothing. Use the query builder's typed
  helpers (`inArray`, placeholders) for anything that is not a scalar.
- Raw inserts supply everything the ORM normally supplies. If ids or
  timestamps default in application code rather than in the database,
  a raw INSERT without them fails, or worse, succeeds with nulls.
- Money is integers in the smallest unit. Multi-table financial writes
  are one transaction. See ENGINEERING-PRINCIPLES.md section 6.

## Schema drift (the silent-drop bug class)

When older tenants lack an attribute newer code expects to write, the
write silently drops. Adding to a canonical seed schema REQUIRES all
of: (1) the seed change, (2) a migration that idempotently inserts it
into every existing tenant, (3) the self-healing service updated to
lazy-create on first write, (4) a contract test locking the helper's
list to the seed. Skipping any of (2) to (4) reintroduces the class.
