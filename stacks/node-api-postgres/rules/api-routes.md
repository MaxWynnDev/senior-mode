---
paths:
  - "**/src/routes/**"
  - "**/src/api/**"
  - "**/src/controllers/**"
  - "**/src/modules/**/*.controller.ts"
---

<!-- SETUP (node-api-postgres): Hono sample; bullets name the Fastify, Express
5, and Nest equivalents. Adapt helper names. Replaces the core `api-boundary.md`; keep one. -->

# API routes

Versioned HTTP surface (`/v1/...`). One router file per resource, mounted
from `src/app.ts`; `src/server.ts` only listens. Handlers orchestrate,
services own the logic, 150 LOC per handler file.

## Required pattern for every route

```ts
import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { requireAuth, requirePermission } from "@/http/auth";
import { rateLimit } from "@/http/rate-limit";
import { ok } from "@/http/respond";
import { createThing } from "@/services/things";

export const things = new Hono<AppEnv>()
  .use(requireAuth())                            // sets c.var.ctx or returns 401
  .post(
    "/",
    requirePermission("things.create"),          // 403 before any I/O
    rateLimit({ key: (c) => c.var.ctx.userId, max: 60, windowMs: 60_000 }),
    zValidator("json", CreateThingSchema),       // 400 with the schema's issues
    async (c) => {
      const ctx = c.var.ctx;                     // tenantId, userId, scopes, requestId
      const result = await createThing(ctx, c.req.valid("json"));
      return ok(c, result, 201);
    },
  );
```

## Conventions

- ONE auth middleware/plugin resolves the caller (session cookie, bearer
  API key) into a typed request context: `c.var.ctx` (Hono), `request.ctx`
  via `decorateRequest` in a `fastify-plugin` wrapped plugin (Fastify),
  `req.ctx` (Express), an `AuthGuard` plus a `@Ctx()` param decorator
  (Nest). Never re-parse a token in a handler.
- Permission check before any I/O: `requirePermission("thing.do")`, not
  mere membership. API keys carry scopes; enforce them per method.
- Validate at the boundary with the framework's native tool: `zValidator`
  with zod (Hono), JSON Schema on `schema.body/querystring/params`
  (Fastify), a `validate(schema)` zod middleware (Express), a global
  `ValidationPipe({ whitelist: true, forbidNonWhitelisted: true })` (Nest).
- Tenant ID comes from `ctx`, never from the body, query, path, or a
  header (access-control bypass). A path may carry a resource id; the
  service verifies it belongs to `ctx.tenantId`.
- `GET` never writes. Caches, prefetchers, and link previews replay it.
- Body size limit and request timeout are set ONCE at the app level and
  never widened per route without a comment: `bodyLimit` (Hono middleware,
  Fastify option, `express.json({ limit })`) plus a request timeout
  (`hono/timeout`, Fastify `requestTimeout`, Node's `server.requestTimeout`
  for Express). Uploads get a streaming route, not a bigger JSON limit.
- Shared response helpers (`ok`, `badRequest`, `unauthorized`,
  `forbidden`, `notFound`, `conflict`) in one module. Error shape is
  `{ error: { code, message, details? } }` with one `code` enum.
- One app-level error handler (`app.onError`, `setErrorHandler`, the
  four-argument Express middleware, a Nest exception filter) maps typed
  errors to that shape and the rest to a 500 with the request id; the
  stack is logged there, never `console.log`ged in a handler.

## What NOT to do

- Do not return a raw database error (`error.message` from pg, Drizzle,
  or Prisma) to the client. It leaks table names and, on a unique
  violation, the value. Map `23505` to `conflict()`, the rest to 500.
- Do not bypass the auth middleware for "internal" routes. Cron and
  webhook routes carry their own gate (shared secret plus timing-safe
  signature) and say so in a comment.
- Do not write to financial tables from a handler; the money services
  enforce the invariants a raw write bypasses.
- Do not add a public route to one allowlist (router, lint contract,
  docs) without the others.

## Money paths

Financial routes carry `regression=pass` in the Senior-Checklist trailer,
a test for the happy AND the failure path that the runner imports, and
error-reporter capture of any silent rollback.
