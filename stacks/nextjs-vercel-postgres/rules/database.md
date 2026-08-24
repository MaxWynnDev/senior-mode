---
paths:
  - "**/db/**"
  - "**/drizzle/**"
  - "**/migrations/**"
---

<!-- SETUP (reference stack: Drizzle ORM over Postgres, Neon in prod):
adapt the helper names and commands to your ORM, or delete. Replaces the
core `data-layer.md` when installed; keep one. -->

# Database

Drizzle ORM over Postgres (a managed Postgres with copy-on-write
branching for prod, local PG or a dev branch for dev).

## Schema files

- `schema/*.ts`: one file per logical domain.
- `schema/index.ts`: barrel export.
- FK references use `onDelete: "cascade"` unless documented otherwise.

## Migrations

- Run ONLY via the sanctioned runner (`pnpm db:migrate:prod`, see
  `scripts/migrate-prod.ts` once you copy it). It verifies the target,
  prints the journal, and demands a typed `APPLY`.
- Migrations must be additive (new column, index, table). Same code must
  work against old and new schemas.
- Destructive column drops happen in a follow-up deploy AFTER code stops
  referencing the column.
- Never put migrations in the build command (`vercel.json` /
  `vercel.ts`). Never run `drizzle-kit migrate` directly against prod.
- The journal entry (`meta/_journal.json`) lands in the same commit as
  the SQL, with a `when` value newer than the last applied entry.
  Parallel sessions generating concurrently can mint a stale one, and
  the runner silently skips it.
- If the app connects as a restricted role (recommended once RLS is on),
  migrations run as the owner; objects a migration creates must be
  owned or granted so the app role can use them.

## Generating migrations

```bash
pnpm drizzle-kit generate
```

Inspect the generated SQL before committing. Trim any auto-added DROP
statements that reference columns you still need.

## Row-level security (tenant isolation)

If you enable Postgres RLS, service functions must set the session GUC
via a helper before querying:

```ts
import { withTenant } from "@/db/with-tenant";

await withTenant(tenantId, async (tx) => {
  return tx.select().from(things);
});
```

Skipping the wrapper returns zero rows from RLS-protected tables
silently. The query won't error, it'll just lie. Always wrap. Two more
sharp edges: `INSERT ... RETURNING` is checked against the SELECT
policy too, and `EXPLAIN` as the owner role does not show the cost the
app role pays.

## Raw SQL is an unchecked cast

`sql\`... = ANY(${jsArray})\`` does not do what it reads as; the driver
serializes the array as a single value. Use `inArray` and the typed
helpers for anything that is not a scalar. A `jsonb` column takes
`JSON.stringify(value)::jsonb`, not the driver's json helper, which
double-encodes.

## Schema drift (the silent-drop bug class)

When older tenants are missing attributes that newer code expects to
write, writes silently drop. To avoid it:

1. Add to the canonical schema definition (your `STANDARD_OBJECTS`
   equivalent).
2. A migration that idempotently inserts the new attribute/status into
   every existing tenant.
3. Update the self-healing service to lazy-create on first write.
4. A contract test that locks the helper's attribute list to the
   canonical seed.

Skipping any of (2) to (4) reintroduces the silent-drop class of bug.
