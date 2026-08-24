<!-- SETUP: stack-neutral rule for the request boundary (HTTP routes, RPC
handlers, GraphQL resolvers, CLI entry points). Scope it to your API layer
by adding frontmatter so it only loads when those files are touched:

---
paths:
  - "src/app/api/**"
  - "src/routes/**"
---

Rules without `paths:` load every session and cost context every turn. The
reference stack profile ships a concrete Next.js version of this rule. -->

# The request boundary

One contract for every handler that accepts input from outside the
process.

## Order of operations

1. Resolve the caller's identity through the ONE shared auth resolver.
   Never query data before auth. Handlers that bypass it (cron, webhook,
   public-token) say so in a comment and carry their own gate: a shared
   secret plus a platform header for cron, a timing-safe signature check
   for webhooks, a hashed-token lookup for public links.
2. Check the fine-grained permission (`requirePermission(ctx, "thing.do")`),
   not mere membership.
3. Rate limit user-facing endpoints. Metered endpoints (LLM, paid APIs)
   also assert a spend budget.
4. Validate the body with a schema at the boundary. Trust within.
5. Call a service. Handlers orchestrate; they do not own business logic.
6. Return the shared response shapes (`success` / `badRequest` /
   `unauthorized` / `forbidden`). Never a raw database error.

## Never

- Accept the tenant or owner ID from the request body, query, or
  headers. It comes from the auth context. Anything else is an
  access-control bypass.
- Write from a GET handler. Caches, prefetchers, link previews, and
  crawlers replay GETs; a read that inserts, spends budget, or sends
  will happen more times than you think.
- Write to financial tables from a handler. Go through the dedicated
  money services, which enforce the invariants a raw write bypasses.
- Add a new public route to one allowlist and not the other (lint
  contract, middleware, docs). Every allowlist, or none.

## Widening a set

Adding a member to an error code enum, permission set, role list, or
action set does not fail to compile at consumers that matched the OLD
members by string literal or prefix. Grep the old member before adding
the new one; prefer a shared predicate or an explicit map over N
literal comparisons.
