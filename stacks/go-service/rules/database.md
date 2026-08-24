---
paths:
  - "**/internal/db/**"
  - "**/db/**"
  - "**/migrations/**"
  - "**/queries/**"
  - "sqlc.yaml"
---

<!-- SETUP (go-service profile: pgx v5 + sqlc + goose over Postgres): adapt
paths and the runner name. Replaces the core `data-layer.md`; keep one. -->

# Database

pgx v5 (`pgxpool`) over Postgres, sqlc-generated queries, goose SQL migrations.

## Layout

- `db/migrations/NNNNN_<name>.sql`: goose files, `-- +goose Up` / `Down`.
- `db/queries/<domain>.sql`: sqlc source, one file per domain.
- `internal/db/` (sqlc `out`): generated `db.go`, `models.go`, `querier.go`,
  `*.sql.go`. Never hand-edit; `sqlc generate`, commit with the query; CI runs `sqlc diff`.
- `internal/db/pool.go`: the ONE `pgxpool.New`; refuses a prod host
  outside `APP_ENV=production`.

## Queries (sqlc)

- Every query over tenant-owned data has `tenant_id = $1` (or
  `sqlc.arg(tenant_id)`) as its first predicate, and the name says so:
  `GetInvoiceForTenant`, `ListItemsByTenant`. A query without it is
  reviewed as a cross-tenant read.
- `emit_interface: true`: services accept `db.Querier`, tests fake it.
- `ON CONFLICT`, `RETURNING`, and `FOR UPDATE` are written in the SQL,
  not reconstructed in Go. Slices: `= ANY($1::uuid[])`; `IN ($1)` with
  a slice compiles, then fails or matches nothing at runtime.
- `errors.Is(err, pgx.ErrNoRows)` maps to the service's `ErrNotFound`;
  a `*pgconn.PgError` with `Code == "23505"` is the idempotency signal.

## Raw string SQL is an unchecked cast

A SQL string outside `db/queries` is invisible to sqlc: the compiler
cannot see the column names, so a renamed column becomes a runtime error
in production, and `fmt.Sprintf` into SQL is an injection on top of that.
Ad-hoc SQL belongs in migrations and `cmd/tools`; services go through sqlc.

## Transactions

```go
tx, err := pool.Begin(ctx)
if err != nil {
	return err
}
defer tx.Rollback(ctx) // no-op after Commit
q := db.New(tx)        // hand q to every service call in this unit of work
return tx.Commit(ctx)
```

- One transaction per financial event. The caller (handler or
  orchestrating service) opens it and passes `db.New(tx)` down.
- Read-modify-write on a balance: `SELECT ... FOR UPDATE` in the same
  transaction, rows locked in a fixed order (by id) so two writers
  cannot deadlock.
- Keep transactions short. No LLM call, webhook, or HTTP request inside
  one; a held connection under load exhausts the pool.

## Money

- `int64` minor units in Go, `BIGINT` in Postgres. Never `float64`,
  never `NUMERIC` in application math.
- `NUMERIC` only at the edge (an external ledger, a tax rate): scan into
  `pgtype.Numeric`, convert once, compute in integers. Splits sum back
  to the whole to the integer cent.
- Idempotency: a unique constraint on `(tenant_id, idempotency_key)`,
  `ON CONFLICT DO NOTHING`, and check the affected-row count. A retried
  webhook is the normal case, not the edge case.

## Migrations (goose)

- Production ONLY through the gated wrapper (`scripts/migrate-prod.sh`,
  see WORKFLOW.md). Never `goose up` pointed at prod by hand, never in
  the Dockerfile, a `release_command`, or an init container.
- Additive first: new column, index, table, constraint. The same binary
  must work against the old and the new schema. Drops ship in a
  follow-up after the code stops referencing the column.
- goose runs each file in a transaction and Postgres DDL is
  transactional, so a failed `Up` rolls back. `CREATE INDEX
  CONCURRENTLY` needs `-- +goose NO TRANSACTION` and `IF NOT EXISTS`.
- `goose create` mints timestamp versions; run `goose fix` before merge
  so mainline is sequential and prod never needs `-allow-missing`.
- `Down` exists to rehearse in staging. Production is fix-forward.
