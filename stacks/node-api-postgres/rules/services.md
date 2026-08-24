---
paths:
  - "**/services/**"
  - "**/src/modules/**/*.service.ts"
---

<!-- SETUP (node-api-postgres): the business-logic layer. Adapt the
helper names to your project. Replaces the core `services.md` when
installed; keep one. -->

# Services

The business-logic layer. Handlers call services; services own the
invariants. Framework-free: a service imports `db`, other services, and
`lib/`, never `hono`, `fastify`, `express`, or a request object. Nest
services are plain classes; the injectable decorator is the only Nest
import allowed.

## Signature contract

```ts
export async function createThing(
  ctx: AuthContext,                 // tenantId, userId, scopes, requestId
  input: CreateThingInput,          // already validated at the boundary
  opts: { tx?: Db } = {},
): Promise<Thing> {
  const exec = opts.tx ?? db;
  // ...
}
```

- `ctx` first. Every query inside filters by `ctx.tenantId` (or runs
  under `withTenant`). A cron entry point may take `tenantId: string`
  alone; a service that takes neither is a bug.
- Accept an optional executor (`tx` for Drizzle and Kysely,
  `Prisma.TransactionClient` for Prisma) and default to the shared
  client. The caller that opens the transaction owns atomicity; a
  service never opens a nested transaction when handed one.
- Per-record access lives in ONE module (`src/lib/access.ts`):
  `canAccessThing(ctx, thing)` plus the SQL-fragment variants for list
  filtering. Tenant scoping alone is not per-record visibility.
- Return domain objects, not ORM rows with every column. Map through a
  `toThing()` in the same file; the serializer works from that.
- Throw typed errors (`NotFoundError`, `ConflictError`,
  `PermissionError`) from `src/lib/errors.ts`; the app-level error
  handler maps them. Never a bare `throw new Error("...")` for a
  client-visible condition.

## Sensitive fields

The canonical list lives in `src/lib/sensitive.ts`
(`SENSITIVE_FIELDS`, `isSensitiveField(slug)`, `redact(obj)`). Every
record passes through `redact()` before it reaches a log line (the pino
`redact` paths are generated from the same list), an export or CSV, a
webhook payload, an error-reporter breadcrumb, or an LLM prompt or tool
result. A new sensitive column adds itself to the list in the same
commit, with the encryption-at-rest and access-log wiring from
ENGINEERING-PRINCIPLES.md section 7.

## Outbound calls

- Through `src/lib/http.ts`: native `fetch` with
  `AbortSignal.timeout(<ms>)`, retry with jitter on 408 / 429 / 5xx, and
  the SSRF check for any tenant-configured URL. Never a bare `fetch` in
  a service.
- Model calls: read `PROMPTING.md` first, keep the prompt module pure
  (no `db` import) so the eval harness can import it; the shell does the
  spend-budget assertion, the call, the retries, the spend record, and
  persistence. Tool handlers receive the full `ctx`, not bare
  `{ tenantId, userId }`, so per-record checks still apply inside them.

## Guards are not immutability

Before claiming a column "never changes", grep every writer: cascades,
resyncs, crons, admin scripts, and the backfill from last month.

## Size

400 LOC per new file (ENGINEERING-PRINCIPLES.md section 12a);
orchestration modules may declare an 800 LOC tolerance. A feature adding
more than 50 lines to a file already over budget triggers a split-first
commit.
