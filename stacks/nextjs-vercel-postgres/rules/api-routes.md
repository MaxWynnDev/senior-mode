---
paths:
  - "**/app/api/**"
  - "**/src/api/**"
---

<!-- SETUP (reference stack: Next.js App Router): adapt the helper names to
your project. Replaces the core `api-boundary.md` when installed; delete
one or the other so the two never disagree. -->

# API routes

Versioned API surface. One `route.ts` per path-segment directory.

## Required pattern for every route

```ts
import { NextRequest } from "next/server";
import {
  getAuthContext,
  unauthorized,
  forbidden,
  success,
  badRequest,
} from "@/lib/api-utils";

export async function POST(req: NextRequest) {
  const ctx = await getAuthContext(req);
  if (!ctx) return unauthorized();

  // Permission check FIRST. Tenant scoping is implicit in ctx.
  if (!hasPermission(ctx, "feature.do")) return forbidden();

  // Rate limit user-facing endpoints
  const rl = await checkRateLimit(`feature:${ctx.userId}`, {
    maxRequests: 60,
    windowMs: 60000,
  });
  if (!rl.allowed) return rateLimitResponse(rl.resetAt);

  // Parse + validate body (zod schema at the boundary)
  const parsed = await parseBody(req, FeatureSchema);
  if (!parsed.ok) return badRequest(parsed.error);

  // Service call (tenant-scoped, access-checked)
  const result = await doFeature(ctx, parsed.data);

  return success(result);
}
```

## Conventions

- Auth context FIRST. Never query data before auth.
- Use the shared auth resolver (cookie + API key both work). Don't roll
  your own session.
- Use shared `success` / `badRequest` / `unauthorized` / `forbidden`
  helpers. Consistent error shapes across the surface.
- Tenant/owner ID comes from `ctx`, never from the request body.
- Per-record access-control helpers on top of tenant scoping.
- Rate limit user-facing endpoints. AI endpoints additionally assert a
  spend budget.
- `GET` never writes. A cache, a prefetch, or a link preview replays it.
- Prefer the Node.js runtime (Fluid Compute) over `runtime = 'edge'`;
  streaming works on Node without it.

## What NOT to do

- Do not accept the tenant ID from the request body. Access-control
  bypass risk.
- Do not bypass the auth resolver for "internal" endpoints. Use an
  admin/api-key gate instead.
- Do not return raw DB errors to clients. Surface friendly messages.
- Do not write to financial tables (payments, payouts, billing) without
  going through the dedicated services. Those services enforce
  invariants a raw DB write would bypass.
- Do not add a public route to the middleware allowlist without also
  adding it to the lint contract (and vice versa).

## Money paths require extra care

Routes that touch financial state should include:

- A `regression=pass` line in the Senior-Checklist trailer
- A test that exercises both the happy and failure paths, imported by
  the runner
- Error-reporter capture of any silent rollback
