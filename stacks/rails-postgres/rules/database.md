---
paths:
  - "db/**"
  - "app/models/**"
---

<!-- SETUP (rails-postgres profile): ActiveRecord over Postgres with the
`strong_migrations` gem. Adapt the model and runner names. Replaces the
core `data-layer.md` when installed; keep one. -->

# Database

ActiveRecord over Postgres. `db/schema.rb` is generated, committed, and
never hand-edited (switch to `db/structure.sql` via `schema_format =
:sql` once you need extensions, triggers, or functions).

## Migrations

- Production migrations run ONLY through `scripts/migrate-prod.sh` (host
  check, `db:migrate:status`, typed `APPLY`). Never `bin/rails db:migrate`
  with a prod `DATABASE_URL`; never `db:prepare` in `bin/docker-entrypoint`.
- Additive first: new column, index, table, constraint. The same code
  must work against old and new schema. Drops ship in a follow-up after
  the code stops referencing the column; `ignored_columns` lands BEFORE
  the `remove_column` migration (ActiveRecord caches columns).
- The migration file and the regenerated `db/schema.rb` land in the same
  commit, with a timestamp newer than the schema header's `version:`.
  Rails applies an older pending version anyway, out of order.
- Backfills are not migrations. The migration adds the column; a
  `backfill-*` script fills it in batches (`in_batches.update_all`).
- `strong_migrations` decides what is safe. When it refuses, use the
  recipe it prints. `safety_assured { }` needs a comment saying why.

```ruby
class AddInvoicesAccountDueOnIndex < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!   # required for :concurrently

  def change
    add_index :invoices, %i[account_id due_on], algorithm: :concurrently, if_not_exists: true
  end
end
```

- Constraints on big tables in two steps: `add_check_constraint ...,
  validate: false` then `validate_check_constraint` in a later
  migration; same for `add_foreign_key ..., validate: false` and
  `validate_foreign_key`. A `NOT NULL` on a large table goes through a
  `NOT VALID` check constraint first. A failed `:concurrently` index
  leaves an INVALID index behind; drop it before re-running.

## Tenant scoping

- Every tenant-owned model has `belongs_to :account` and a composite
  index starting with `account_id`.
- Queries go through the association (`account.invoices`) or an
  explicit `where(account_id:)`. `default_scope` is a wrapper of last
  resort: `unscoped`, `Model.new`, and callbacks slip past it.
- If you turn on Postgres RLS, the app-level filter stays. Set the
  session variable with `SET LOCAL` inside the transaction, never a bare
  `SET` on a pooled connection. An unwrapped query returns zero rows
  silently: it does not error, it lies.

## Raw SQL is an unchecked cast

`connection.execute("... WHERE id IN (#{ids.join(',')})")` is both an
injection and a cast nobody checked. Use `where(id: ids)`, or
`sanitize_sql_array(["... = ANY(ARRAY[?]::bigint[])", ids])`, or
`exec_query` with binds. `execute` returns a `PG::Result` of STRINGS: no
type casting, no `Time.zone`. A `jsonb` column takes `value.to_json`,
not a Ruby hash interpolated into a string. `insert_all` / `upsert_all`
/ `update_all` / `update_column` skip validations and callbacks, and the
last two skip `updated_at`; raw writes supply everything the model
normally supplies.

## Money and transactions

- Money is integer minor units: `amount_cents` (integer) plus
  `amount_currency`, which is what `money-rails` `monetize` expects.
  Never a `float` column; `decimal` (BigDecimal) is for rates, not for
  stored amounts. Sum in SQL with `sum(:amount_cents)`.
- Multi-table financial writes are one `ApplicationRecord.transaction do
  ... end`. A nested `transaction` JOINS the outer one; on Postgres an
  error rescued inside the inner block still aborts the outer
  transaction. Use `requires_new: true` when you need a savepoint.
- Read-modify-write goes through `record.with_lock { ... }`
  (`SELECT ... FOR UPDATE`), never `reload` + `update`.
- Idempotency is a unique index plus `create_or_find_by` or
  `insert_all(unique_by:)`, not a "check then insert".
- Side effects fire from `after_commit`, never `after_save`; a job
  enqueued mid-transaction runs before the row exists.
