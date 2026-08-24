---
paths:
  - "packages/shared/**"
---

<!-- SETUP (reference stack, monorepo only): relevant if you keep a shared
package consumed by the app, scripts, and other packages. Delete if you
have a single app. -->

# Shared package

Code shared between the app, scripts, and packages. Pure TypeScript, no
runtime dependencies on the web framework or ORM.

## Canonical schema definition

If you keep a canonical object/schema definition (a `STANDARD_OBJECTS`
equivalent) that seeds new tenants, it is referenced by your
CSV/import mapping, your self-healing services, and your schema-drift
migrations.

## When changing the canonical schema

Adding a new attribute or status REQUIRES:

1. The change here.
2. A migration that idempotently inserts it into every existing tenant.
3. Updates to any self-healing service that mirrors the canonical seed.
4. A contract test that locks the helper's required list to the
   canonical seed.

Skipping any of (2) to (4) creates the silent-drop bug class. See
`database.md`.

## Build and typecheck

```bash
pnpm --filter <shared-pkg> build
```

## Versioning

Workspace-local, no semver. Breaking changes land with the consumer
changes in the same commit.
