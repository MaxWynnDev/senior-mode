---
paths:
  - "**/app/services/**"
  - "**/services/**"
---

<!-- SETUP (python-fastapi-postgres): the business-logic layer. Adapt module
names to your project. Replaces the core `services.md` when installed;
keep one. -->

# Services

The business-logic layer. Routers call services; services own the
invariants. Some modules here grow into god-files; watch the LOC budget.

## Conventions

- Signature: `async def create(session: AsyncSession, ctx: AuthContext,
  data: ThingCreate) -> Thing`. The session is the first parameter and
  the tenant travels in `ctx`. A service never builds its own session
  or engine and never calls `session.commit()`; the caller owns the
  transaction so several calls compose into one atomic write. Sync
  variants take `Session` and drop `async`.
- No `fastapi` imports: no `HTTPException`, no `Request`, no `Depends`.
  Raise `DomainError` subclasses from `app/core/errors.py` (`NotFound`,
  `Forbidden`, `Conflict`); the app maps them once.
- Every query is tenant-scoped through `ctx.tenant_id`. Per-record
  visibility beyond that lives in ONE module, `app/core/access.py`:
  `can_access_thing(ctx, thing)` and `access_filter_things(ctx)`, which
  returns a SQLAlchemy clause for list queries. Tenant scoping alone is
  not per-record visibility.
- Idempotent writes for anything that can be retried (webhook, client
  retry, cron re-fire): a unique constraint plus
  `insert(...).on_conflict_do_nothing()` from
  `sqlalchemy.dialects.postgresql`, or a `seen:<id>` key.
- Money is `int` minor units end to end. `Decimal` appears only at the
  edge that parses or renders a display string; `float` never does. One
  financial event is one `session.begin()` with its audit row inside.
- Sensitive attribute slugs (SSN, bank, anything regulated) pass through
  `is_sensitive_attribute` in `app/core/sensitive.py` before a prompt, a
  log line, an export, or a third party.
- Tool handlers a model can call receive the full `AuthContext`, not a
  bare `(tenant_id, user_id)`, so per-record access checks still apply
  inside the tool.
- A guard on one write path is not immutability: cascades, resyncs,
  crons, and admin scripts write the same columns through other doors.
  Grep every writer before claiming "never".

## Async discipline

- A sync call inside `async def` blocks the event loop for every
  request in flight. Sync-only libraries go through `asyncio.to_thread`
  (or `starlette.concurrency.run_in_threadpool`).
- Outbound HTTP is one shared `httpx.AsyncClient` with a default
  timeout, created in the lifespan handler. A hung upstream with no
  timeout holds a connection and, under load, exhausts the pool.
- Background work that must survive the request is a job row plus a
  worker, not `BackgroundTasks`; the latter dies with the process.

## Adding a model-powered service

Read `PROMPTING.md` at repo root first, then copy your most thorough
existing call site:

- A pure prompt module (`app/services/<name>_prompt.py`): system prompt
  constant with `cache_control: ephemeral`, user-prompt builder
  (including today's date if relevant), post-parse validator. No
  `app.db` or `fastapi` import; the eval harness imports it.
- The shell: spend-budget assertion before send, retry on 408 / 429 /
  500 / 502 / 503 / 504 / 529, spend record after response, persistence.
- Model ID from the one config module; the pricing table knows it.

The kit's AI-feature scaffold command generates this skeleton.

## God-file LOC discipline

400 LOC per new file (ENGINEERING-PRINCIPLES section 12a). Service
orchestration modules carry an 800 LOC tolerance. A feature that adds
more than 50 lines to a file already over budget triggers a split-first
commit.
