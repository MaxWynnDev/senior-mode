<!-- SETUP (rust-service): the business-logic layer. Scope this rule by
adding frontmatter at the top of the file (where the file lives depends
on the agent adapter):

---
paths:
  - "**/src/services/**"
  - "**/src/domain/**"
---

Name your access-control module and sensitive-attribute list where the
brackets are. Replaces the core `services.md` when installed; keep one. -->

# Services

The business-logic layer. Handlers and `src/bin/*` tools call services;
services own the invariants.

## Conventions

- Every service function takes the auth context (or at minimum a
  `TenantId`) as an explicit argument and filters by it. Never query
  without it.
- Generic over the executor, so a caller can compose several calls into
  one atomic write:

  ```rust
  pub async fn create(
      db: impl sqlx::PgExecutor<'_>,
      ctx: &AuthCtx,
      input: CreateThing,
  ) -> Result<Thing, ThingError> { /* one statement */ }

  pub async fn transfer(
      tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
      ctx: &AuthCtx,
      input: Transfer,
  ) -> Result<(), MoneyError> { /* several statements; NEVER commits */ }
  ```

  Callers pass `&pool` for a single statement or `&mut *tx` inside a
  transaction. A function that runs several statements takes
  `&mut Transaction` and leaves `commit()` to the caller who opened it.
- Ids are newtypes: `TenantId(Uuid)`, `UserId(Uuid)` with
  `#[derive(sqlx::Type)] #[sqlx(transparent)]`. Two `Uuid` arguments in
  the wrong order compile; two newtypes do not.
- Errors: one `thiserror` enum per service module. Variants for
  expected failures (`NotFound`, `Forbidden`, `Conflict`, `Insufficient`),
  `#[from] sqlx::Error` for the rest. Handlers map variants to status
  codes. `anyhow` is for binaries, not for library code.
- Access control lives in ONE module (`<src/access.rs>`):
  `can_access_x(ctx, &row)` and the SQL-fragment variants for list
  filtering. Tenant scoping alone is not per-record visibility.
- Sensitive data never reaches a log line or a model by accident:
  credentials are `secrecy::SecretString` (its `Debug` prints
  `[REDACTED]`); structs carrying PII get a manual `impl Debug` that
  masks those fields, so `{:?}` cannot leak; spans use
  `#[tracing::instrument(skip(body, token))]`; anything headed to a
  model, an export, or a third party is filtered through the canonical
  list (`<is_sensitive_attribute>`).
- Tool handlers that a model can call receive the full `AuthCtx`, not a
  bare `(tenant_id, user_id)`, so per-record checks still apply inside.
- No `.unwrap()` on I/O or DB results. `?` with a typed error; `expect`
  only on an invariant, with the reason in the string.
- Blocking work (argon2, big serde, sync SDKs, zip) runs in
  `tokio::task::spawn_blocking`. A blocking call on a worker thread
  stalls every request scheduled on it.
- A guard on one write path is not immutability. Before claiming a
  column "never changes", grep every writer: crons, backfills in
  `src/bin/`, admin tools, cascades.

## Adding an LLM-powered service

Read `PROMPTING.md` first, then copy your most thorough existing call
site. Keep the prompt constants, builders, and the response validator
in a PURE module (no `sqlx`, no `axum` imports) so the eval harness can
import it; the shell around it does the budget gate, the call with
retries on 408 / 429 / 500 / 502 / 503 / 504 / 529, the spend record,
and persistence. Model ID from the one config module.

## Size

400 LOC per new file (ENGINEERING-PRINCIPLES.md section 12a).
Orchestration modules may carry a declared 800 LOC tolerance. A feature
that adds more than 50 lines to a file already over budget triggers a
split-first commit; a `mod.rs` with `pub use` keeps call sites stable
across the split.
