# Stack profile: nextjs-vercel-postgres (recommended)

The kit's recommended stack for a NEW web application, packaged as an
overlay. Install with `bash install.sh --profile nextjs-vercel-postgres
<repo>`, or copy the pieces by hand. Nothing here is required by the
core kit; an existing project on another stack skips this folder
entirely (see `../../STACK.md`).

## What it assumes

- Next.js App Router with TypeScript, React, Tailwind, shadcn/ui.
- Postgres with copy-on-write branching (Neon), Drizzle ORM with SQL
  migrations and a journal.
- A vetted auth library for sessions (cookie + API key through one
  resolver).
- Vercel for deploys (Fluid Compute, Node 24), GitHub Actions for CI, a
  CI-gated production deploy, a rolling release.
- pnpm; a monorepo layout with the web app at `apps/web` is supported
  by the templates' path candidates, and a single-app layout works too.
- Playwright for e2e, with a sign-in-once storage-state fixture.

## What's in the overlay

| Path | Installs as | Purpose |
|---|---|---|
| `rules/api-routes.md` | `.senior-mode/rules/` | route contract with real helper names, scoped to `**/app/api/**` |
| `rules/components.md` | `.senior-mode/rules/` | React + Tailwind + shadcn conventions, scoped to components and `.tsx` pages |
| `rules/database.md` | `.senior-mode/rules/` | Drizzle schema, migrations, RLS wrapper, raw-SQL casts, scoped to `**/db/**` |
| `rules/services.md` | `.senior-mode/rules/` | business-logic layer, scoped to `**/services/**` |
| `rules/scripts.md` | `.senior-mode/rules/` | operational scripts, scoped to `**/scripts/**` |
| `rules/shared-package.md` | `.senior-mode/rules/` | monorepo shared package (delete for a single app) |
| `commands/stage.md` | `.senior-mode/commands/` | `/stage [migrate\|down]` |
| `commands/qa-sweep.md` | `.senior-mode/commands/` | `/qa-sweep [staging\|url]` |
| `WORKFLOW.md` | repo root | the concrete pipeline (replaces the core template) |
| `QA-SWEEP.md` | repo root | the sweep brief and findings contract |
| `qa/` | `senior-mode-qa/` (staging) | Playwright page sweep, nightly workflow, stage scripts, sandbox seed checklist, sweep launcher, pipeline dashboard; see `qa/README.md` for where each template goes |

The profile's rules REPLACE the core's `api-boundary.md`,
`data-layer.md`, `ui.md`, `services.md`, and `scripts.md`. The kickoff
asks you to keep one of each pair so they never disagree.

## Platform notes worth knowing (as of mid-2026)

- Fluid Compute is the default: ordinary Node.js, 300s default
  timeout, instances reused across requests, WebSockets supported,
  functions up to 5 GB and request bodies up to 100 MB. Do not reach
  for `runtime = 'edge'`; streaming and SSE work on Node.
- `vercel.ts` (`@vercel/config`) is the typed replacement for
  `vercel.json`. Keep migrations out of the build command either way.
- Postgres and KV come from the Vercel Marketplace (Neon, Upstash),
  not first-party products.
- AI features: the AI SDK through the AI Gateway with plain
  `"provider/model"` strings; Vercel Sandbox for untrusted code.
- Rolling Releases (canary rollout with auto-rollback) are GA; the
  profile's `WORKFLOW.md` assumes them.
- Enable the `typescript-lsp` plugin for symbol-aware navigation.

## Install by hand

1. Rules and commands: copy into `.senior-mode/rules/` and
   `.senior-mode/commands/`.
2. Docs: `WORKFLOW.md` and `QA-SWEEP.md` to the repo root.
3. QA pack: follow `qa/README.md` (spec into your e2e dir, workflow
   into `.github/workflows/`, stage scripts into `scripts/` with the
   `stage:up` / `stage:down` package scripts, dashboard templates into
   the app).
4. Seed the QA sandbox tenant per `qa/QA-SANDBOX-SEED-CHECKLIST.md`.
