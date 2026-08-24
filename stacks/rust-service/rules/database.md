<!-- SETUP (rust-service: sqlx over Postgres): scope this rule by adding
frontmatter at the top of the file (where the file lives depends on the
agent adapter):

---
paths:
  - "**/src/db/**"
  - "**/migrations/**"
  - "**/.sqlx/**"
---

Name your sanctioned runner where the brackets are. Replaces the core
`data-layer.md` when installed; keep one. -->

# Database

sqlx over Postgres. Queries are checked against the real schema at
compile time; the schema is defined by SQL files under `migrations/`.

## Queries

- `sqlx::query!` / `query_as!` for everything static. The macro checks
  the SQL, the bind types, and the column nullability against
  `DATABASE_URL` at build time, or against `.sqlx/` when `SQLX_OFFLINE`
  is set. A query that compiles matches the schema.
- `sqlx::query(&string)` and `QueryBuilder` are unchecked casts: the
  SQL, the bind types, and the row shape are your assertion. Use them
  only for genuinely dynamic SQL (a sort column from an allowlist,
  optional filters), bind every value with `.bind()`, never format user
  input into the string, and keep the allowlist next to the query.
- Nullability overrides (`"col!"`, `"col?"`, `"col: MyType"`) are claims;
  a wrong `!` panics at decode time. Aggregates and outer joins need
  them; nothing else should.
- Every query that returns tenant-owned data has `WHERE tenant_id = $1`
  or joins through a table that does; `query!` cannot check that. If
  RLS is on, the app-level filter stays and a `SET LOCAL app.tenant_id`
  helper wraps the transaction; an unwrapped query returns zero rows
  silently. A list binds as `= ANY($1)`; `IN ($1)` binds one value.
- Money is `i64` minor units in a `BIGINT`, never `f64`; `NUMERIC` only
  with `rust_decimal` and a reason in the column comment. Time is
  `TIMESTAMPTZ`, never `TIMESTAMP`.

## Transactions

```rust
let mut tx = pool.begin().await?;
sqlx::query!("SELECT balance FROM accounts WHERE id = $1 FOR UPDATE", id)
    .fetch_one(&mut *tx).await?;
sqlx::query!("UPDATE accounts SET balance = balance - $2 WHERE id = $1", id, amount)
    .execute(&mut *tx).await?;
tx.commit().await?;   // dropping tx without commit rolls back
```

- Multi-table financial writes are one transaction, audit row included.
- `SELECT ... FOR UPDATE` before any read-modify-write on a balance,
  counter, or status machine. Without it two workers both read the old
  value and both write.
- Retried writes (webhooks, client retries, cron re-fires) are
  idempotent: a unique index on the idempotency key and
  `ON CONFLICT (key) DO NOTHING`, in the same transaction as the write.
- Hold a transaction for the write, not across an outbound HTTP call;
  it pins a pool connection and a row lock for the upstream's timeout.

## Migrations

- `sqlx migrate add <name>` creates `migrations/<timestamp>_<name>.sql`.
  Plain SQL, one concern per file, same commit as the code that needs
  it. `-r` (reversible pairs) only where a down migration is real.
- Dev, CI, staging: `sqlx migrate run`. Prod: ONLY through the
  sanctioned runner (`<scripts/migrate-prod.sh>`, see WORKFLOW.md); never
  a prod URL in the shell, never `sqlx::migrate!().run()` at start.
- Additive first: new table, nullable or defaulted column, index. The
  same binary must work against the old and the new schema. Drops ship
  in a follow-up after the code stops referencing the column.
- Applied migrations are immutable. sqlx stores a checksum in
  `_sqlx_migrations` and refuses to run when a file changed after it
  was applied. Fix forward with a new file.
- `CREATE INDEX CONCURRENTLY` cannot run inside a transaction: start
  that file with `-- no-transaction` and keep it alone in the file.
- After any migration or `query!` change: `cargo sqlx prepare`, commit
  `.sqlx/`. CI runs `cargo sqlx prepare --check`; a stale cache fails
  the build, which is the point.

## Schema drift (the silent-drop bug class)

When older tenants lack an attribute newer code expects to write, the
write silently drops. Adding to a canonical seed REQUIRES: (1) the seed
change, (2) a migration that idempotently inserts it into every existing
tenant, (3) the self-healing service lazy-creating on first write, (4) a
test locking the helper's list to the seed. Skip none of (2) to (4).
