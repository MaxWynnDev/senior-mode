# Stack profile: node-api-postgres

The backend sibling of `nextjs-vercel-postgres`: a TypeScript HTTP
service with no browser surface, packaged as an overlay. Install with
`bash install.sh --profile node-api-postgres <repo>`, or copy the pieces
by hand. Nothing here is required by the core kit. Detection
(`bash stacks/detect.sh`) keys on the HTTP framework in `package.json`
and never fires on `next`; a Next.js app with API routes wants the
sibling profile instead.

## What it assumes

- TypeScript on Node 22+ (Bun works; the commands assume pnpm on Node).
  ESM, strict `tsconfig`, `tsc --noEmit` for typecheck, `tsx` for dev
  and scripts, `dist/` from `pnpm build` in the image.
- One HTTP framework that is not Next.js: Hono, Fastify, Express 5, or
  NestJS. The rules show Hono and name the equivalent in each of the
  others.
- Postgres through Drizzle (SQL migrations plus a journal) or Prisma
  (`migrate deploy`). Kysely follows the Drizzle shape.
- vitest for unit and integration tests (integration against an
  ephemeral Postgres in CI), Biome or ESLint + Prettier.
- A Docker image built in CI, tagged by git SHA, deployed to Fly.io,
  Railway, or Render behind a CI gate; a `/health` route that reports
  the running SHA.
- One auth middleware that resolves session cookies and scoped API keys
  into a request context. Multi-tenant by default (delete the tenant
  lines if single-tenant).
- Layout: `src/server.ts` (listen only), `src/app.ts` (wiring),
  `src/routes/` or `src/modules/`, `src/services/`, `src/db/`,
  `scripts/`. A monorepo with the service under `apps/api` works with
  the rules' path globs.

## What's in the overlay

| Path | Installs as | Purpose |
|---|---|---|
| `rules/api-routes.md` | path-scoped rule (location depends on the agent adapter) | route contract: one auth middleware, boundary validation, response helpers, limits |
| `rules/database.md` | path-scoped rule (location depends on the agent adapter) | Drizzle/Prisma schema, migrations, tenant filters, transactions, idempotency |
| `rules/services.md` | path-scoped rule (location depends on the agent adapter) | business-logic layer, executor injection, sensitive-field filtering |
| `rules/scripts.md` | path-scoped rule (location depends on the agent adapter) | operational scripts under `scripts/*.ts` |
| `WORKFLOW.md` | repo root | the concrete pipeline (replaces the core template) |
| `profile.json` | not installed | commands and layout the kit's commands and agents read |
| `detect.txt` | not installed | signals for `stacks/detect.sh` |

The profile's rules REPLACE the core's `api-boundary.md`,
`data-layer.md`, `services.md`, and `scripts.md`. The core `ui.md` does
not apply to a headless service; delete it. No `/stage`, `/qa-sweep`, or
QA pack: an API is verified by its integration suite and a post-deploy
smoke script, not a browser sweep.

## Platform notes worth knowing (as of mid-2026)

- Node 22 is in maintenance LTS until April 2027; Node 24 is the active
  LTS. Both have native `fetch`, `AbortSignal.timeout(ms)`,
  `AbortSignal.any()`, `node --env-file`, `node --watch`, and
  `require(esm)`. Node 22.18+ and 24 run `.ts` files directly by
  stripping types (no enums, namespaces, or path aliases), enough for a
  script but not a reason to drop `tsx` or the build step.
- Hono runs the same code on Node (`@hono/node-server`), Bun, Deno, and
  Cloudflare Workers; validation is `@hono/zod-validator`, request state
  is typed through the `Variables` generic, `hono/body-limit` and
  `hono/timeout` are one-line middlewares.
- Fastify validates body, query, params, and headers with JSON Schema
  (Ajv) and serializes responses from the response schema, which also
  drops undeclared properties (a leak guard, and a surprise when a field
  goes missing). `bodyLimit` defaults to 1 MiB; decorators only cross
  plugin boundaries when the plugin is wrapped in `fastify-plugin`.
- Express 5 forwards a rejected promise from an async handler to the
  error middleware, so `express-async-errors` is gone; `req.query` is a
  read-only getter, and path-to-regexp 8 changed wildcard and optional
  syntax (`/*splat`, `{/:id}`). Timeouts come from Node's
  `server.requestTimeout` (300 s default) and `headersTimeout` (60 s).
- NestJS: `ValidationPipe({ whitelist: true, forbidNonWhitelisted: true,
  transform: true })` globally; guards run before pipes; the Express
  adapter is the default and the Fastify adapter is a drop-in.
- Prisma: `migrate dev` is a development tool (shadow database, can
  reset the database); `migrate deploy` applies pending migrations
  without a shadow database and is the only one that touches prod.
  `_prisma_migrations` records each applied file's checksum, so an
  applied file is immutable: fix forward. Drizzle: `drizzle-kit
  generate` writes the SQL and the journal entry; the migrator applies
  entries whose journal timestamp is newer than the last applied row.
- Fly.io: `fly deploy --image <ref>` deploys a prebuilt image, which
  makes rollback a redeploy of the previous SHA's image;
  `[deploy] release_command` in `fly.toml` runs before traffic and is
  where auto-migration sneaks in. Leave it unset. Railway and Render
  redeploy a previous build from their dashboards.
- Pin pnpm with the `packageManager` field and install it explicitly in
  the Dockerfile; do not depend on Corepack being present in the base
  image.

## Install by hand

1. Rules: copy `rules/*.md` into the directory your agent adapter reads
   path-scoped rules from (`install.sh --profile` does this), and delete
   the core `api-boundary.md`, `data-layer.md`, `services.md`,
   `scripts.md`, and `ui.md`.
2. `WORKFLOW.md` to the repo root, replacing the core template.
3. Package scripts named as in `profile.json` (`dev`, `typecheck`,
   `lint`, `test`, `test:integration`, `build`, `db:migrate`,
   `db:migrate:prod`).
4. CI: a workflow with a `postgres:16` service container for the
   integration job, and a deploy job gated on it (see `WORKFLOW.md`).
5. `fly.toml` / `railway.json` / `render.yaml` with a health check on
   `/health`, and the platform token as a GitHub secret.

## What to adapt per framework

- **Hono**: the rules' samples are Hono; `app.onError` is the error
  mapper and `c.var.ctx` the request context. Nothing to adapt.
- **Fastify**: JSON Schema on `schema` replaces zod, `request.ctx` via
  `decorateRequest` in a `fastify-plugin` wrapped auth plugin replaces
  `c.var.ctx`, `setErrorHandler` replaces `app.onError`, and every route
  declares a response schema.
- **Express 5**: the auth middleware sets `req.ctx`, a `validate(schema)`
  middleware wraps zod, `express.json({ limit })` goes first and the
  four-argument error middleware last.
- **NestJS**: an `AuthGuard` sets `request.ctx`, a `@Ctx()` param
  decorator reads it, `ValidationPipe` replaces zod, an
  `ExceptionFilter` replaces `app.onError`, and services stay plain
  classes so they remain framework-free.
