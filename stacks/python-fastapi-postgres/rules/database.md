---
paths:
  - "**/app/db/**"
  - "**/app/models/**"
  - "**/alembic/**"
  - "**/migrations/**"
---

<!-- SETUP (python-fastapi-postgres: SQLAlchemy 2.x + Alembic): adapt module
names, pick async or sync. Replaces the core `data-layer.md`; keep one. -->

# Database

SQLAlchemy 2.x over Postgres in every environment (never SQLite in
tests; the dialect differences hide bugs). Alembic owns the graph.

## Models

- `app/models/<domain>.py`, one file per domain. `Base` in
  `app/models/base.py` carries a `MetaData(naming_convention=...)`;
  without it autogenerate cannot drop or rename what it cannot name.
- `app/models/__init__.py` imports every model module; `alembic/env.py`
  imports that package. A model missing there is a DROP TABLE.
- `Mapped[...]` and `mapped_column(...)` only. `DateTime(timezone=True)`
  on every timestamp; `BigInteger` for money in minor units, never
  `Float` or `Numeric` in arithmetic. FK columns use
  `ondelete="CASCADE"` with `passive_deletes=True` on the relationship.

## Sessions and transactions

- One engine per process (`app/db/session.py`): `create_async_engine`
  plus `async_sessionmaker(expire_on_commit=False)`, or the sync pair.
  `get_session` yields one session per request; nothing else builds one.
- Transactions are `async with session.begin():` at the caller. No
  `session.commit()` inside services; the caller composes several
  service calls into one atomic write. Savepoints: `begin_nested()`.
- Async lazy loads raise `MissingGreenlet`. Declare `selectinload` or
  `joinedload` on the query and `lazy="raise"` on relationships.

## Migrations

- Run ONLY via the sanctioned runner (`scripts/migrate-prod.sh`, see
  `WORKFLOW.md`). Never `alembic upgrade head` from a shell pointed at
  prod, never in a Dockerfile `CMD`, `release_command`, or pre-deploy hook.
- Additive first: a nullable or defaulted column, an index, a table.
  The same code works against old and new schemas. Drops ship in a
  follow-up after the code stops referencing the column.
- Exactly one head. Two sessions each minting a revision off the same
  parent produce two; `alembic merge heads` or re-parent before push.
  CI counts `(head)` lines and fails on anything but 1.
- The revision lands in the same commit as the model change, with
  `down_revision` equal to the current head. `alembic check` in CI
  proves models and graph agree. Prod never downgrades.
- `CREATE INDEX CONCURRENTLY` and `ALTER TYPE ... ADD VALUE` cannot run
  inside the default single transaction; give them their own revision
  wrapped in `with op.get_context().autocommit_block():`.

## Autogenerate pitfalls (inspect every generated file)

- `server_default` changes are not compared unless
  `compare_server_default=True` is set in `env.py`. Write them by hand.
- Enum member changes are never detected. Add a value with
  `op.execute("ALTER TYPE thing_status ADD VALUE 'archived'")` in an
  autocommit block; there is no DROP VALUE, so downgrade is a rebuild.
- A rename comes out as drop plus add. Rewrite it as
  `op.alter_column(..., new_column_name=...)` or the data is gone.

## Raw SQL is an unchecked cast

`text()` binds by name (`:id`), never by f-string. A Python list bound
to `IN :ids` is one value, not a set: use `bindparam("ids",
expanding=True)` or, better, `select(Thing).where(Thing.id.in_(ids))`.
A `text()` insert supplies every column the ORM would default in Python
(`id`, `created_at`); a missing one succeeds with NULL.

## Tenant isolation

Every query over tenant-owned rows carries
`.where(Thing.tenant_id == ctx.tenant_id)`, or goes through
`with_tenant(session, tenant_id)` (a `SET LOCAL app.tenant_id` inside
the transaction) if RLS is on. Under RLS an unwrapped query returns zero
rows silently: it does not error, it lies. The app filter stays either way.

## Schema drift (the silent-drop bug class)

When older tenants lack an attribute newer code expects to write, the
write silently drops. Adding to the canonical seed REQUIRES all of: the
seed change, a revision that idempotently inserts it into every tenant
(`ON CONFLICT DO NOTHING`), the self-healing service updated to
lazy-create on first write, and a contract test locking the list.
