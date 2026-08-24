---
paths:
  - "**/models.py"
  - "**/models/**"
  - "**/migrations/**"
---

<!-- SETUP (django-postgres): the `paths:` frontmatter above scopes this
rule; adapters that ignore frontmatter map the same globs in their own
config. Replaces the core `data-layer.md` when installed; keep one. -->

# Database

Django ORM over Postgres (psycopg 3). One `models.py` (or a `models/`
package) and one `migrations/` directory per app.

## Models

- Every tenant-owned model has `tenant = ForeignKey(..., on_delete=PROTECT)`
  and a manager whose `for_tenant(tenant)` is the only way lists are
  built. Tenant scoping is the first filter, per-record access the second.
- Invariants live in `Meta.constraints` (`UniqueConstraint`,
  `CheckConstraint`), not only in `clean()`: `QuerySet.update()` and
  `bulk_create()` skip `save()`, `clean()`, and signals.
- `db_default` (Django 5.0) for defaults the database must own; `default=`
  runs in Python. Timestamps use `timezone.now`, never `datetime.now`.

## Migrations

- Prod runs ONLY through the sanctioned runner (`scripts/migrate-prod.sh`):
  host check, `showmigrations --plan`, `sqlmigrate` review, typed
  `APPLY`, then `migrate`. Never in `release_command`, a pre-deploy
  command, the Dockerfile, or the entrypoint. Never a shell at prod.
- Additive first. New column (nullable or `db_default`), index, table,
  constraint. The same image must run against the old and new schema,
  because migrate and deploy are separate steps. Drops, renames, and
  type changes ship in a follow-up after the code stops referencing them.
- A model change and its migration land in the same commit. CI runs
  `makemigrations --check --dry-run`; a missing migration is a red
  build. Two leaf nodes in one app mean two sessions minted a
  migration: `makemigrations --merge`, then read the merge.
- `RunPython` always carries a `reverse_code` (`RunPython.noop` when
  the forward is idempotent) and uses `apps.get_model()`, never an
  import. Backfills over large tables go in a management command; a
  migration holds one transaction and its locks for its whole run.
- Postgres locks: a column with a constant default is metadata only;
  a type change or `NOT NULL` on a populated column rewrites or scans
  under `ACCESS EXCLUSIVE`. Plain `AddIndex` blocks writes; use
  `AddIndexConcurrently` with `atomic = False`.
- Squash only after every environment is past the range; delete the
  originals in a later commit. Read `sqlmigrate <app> <name>` before
  committing: the autodetector emits `RemoveField` for anything it thinks is gone.

## Raw SQL is an unchecked cast

`connection.cursor()`, `.raw()`, and `RawSQL` bypass every check the
ORM does:

```py
cur.execute("... WHERE id = ANY(%s)", [ids])     # list adapts to an array: correct
cur.execute("... WHERE id IN %s", [tuple(ids)])  # psycopg2 only; psycopg 3 sends a record and fails
cur.execute("... WHERE id IN %s", [ids])         # list becomes ARRAY[...] inside IN: SQL error
```

A `dict` needs the driver's `Jsonb` adapter or it raises "cannot adapt
type". A literal `%` in a parameterized query is `%%`. Raw inserts
supply everything the ORM would: Python-side defaults do not exist in the database.

## Money, transactions, locks

- Amounts at rest and in math are integer minor units in
  `BigIntegerField` next to a `currency` field. Never `FloatField`;
  `DecimalField` only for rates. ENGINEERING-PRINCIPLES.md section 6.
- Every multi-table write is `with transaction.atomic():` in the
  service, the audit-log row inside it. A swallowed `DatabaseError`
  inside the block aborts the transaction; the next query raises
  `TransactionManagementError`.
- Read-modify-write on a row uses `select_for_update()` inside
  `atomic()` (outside it raises); `F()` expressions for counters.
- Side effects (email, enqueue, webhook) go through
  `transaction.on_commit()`, or a rollback still sends.

## Schema drift (the silent-drop bug class)

When older tenants lack an attribute newer code expects to write, the
write silently drops. Adding to a canonical seed REQUIRES: (1) the seed
change, (2) a `RunPython` migration that idempotently inserts it into
every tenant, (3) the self-healing service updated to lazy-create on
first write, (4) a contract test locking the helper's list to the seed.
