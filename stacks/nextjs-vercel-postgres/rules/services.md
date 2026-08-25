---
paths:
  - "**/services/**"
---

<!-- SETUP (reference stack): the business-logic layer. Adapt the helper
names to your project. Replaces the core `services.md` when installed;
keep one. -->

# Services

The business logic layer. Some files here can grow into god-files; watch
the LOC budget.

## Conventions

- Every service is tenant-scoped. The first arg or context object
  carries the tenant ID. Never query without it.
- Access-control helpers live in one module (e.g.
  `lib/access.ts`): `canAccessX`, `canAccessY`, and the SQL-fragment
  variants for list filtering.
- Accept an optional `tx` executor so callers can compose multi-step
  writes into one transaction.
- Sensitive attribute slugs (SSN, bank, anything regulated) are filtered
  before they reach the LLM. Keep the canonical list in one place.
- Tool handlers that hit the model must pass full auth-context-shaped
  objects, not just `{tenantId, userId}`, so per-record access checks
  still apply inside the tool.
- A guard on one write path is not immutability: cascades, resyncs, and
  crons write the same columns through other doors. Grep every writer
  before claiming "never".

## Adding a new Claude-powered service

Read `PROMPTING.md` at repo root first, then copy your most thorough
existing AI call site:

- A pure prompt module (`<name>-prompt.ts`): system prompt constant with
  `cache_control: ephemeral`, user-prompt builder (including today's
  date if relevant), post-parse validator. No `@/db` import; the eval
  harness imports it.
- The shell: spend-budget assertion before send, retry on 408 / 429 /
  500 / 502 / 503 / 504 / 529, spend record after response, persistence.
- Model ID from the one config module; the pricing table knows it.

The `/new-ai-feature <name>` slash command scaffolds this skeleton.

## God-file LOC discipline

400 LOC per new file (ENGINEERING-PRINCIPLES section 12a). Service
orchestration modules carry an 800 LOC tolerance. Do not add to a
god-file without considering a split.
