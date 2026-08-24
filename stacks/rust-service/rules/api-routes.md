<!-- SETUP (rust-service: axum on tokio): scope this rule to your handler
modules by adding frontmatter at the top of the file (where the file
lives depends on the agent adapter):

---
paths:
  - "**/src/routes/**"
  - "**/src/http/**"
  - "**/src/api/**"
---

Adapt the type and module names to your project. Replaces the core
`api-boundary.md` when installed; keep one so the two never disagree. -->

# API routes (axum handlers)

One module per resource under `src/routes/`, each exposing
`pub fn router() -> Router<AppState>`, merged in `src/routes/mod.rs`.
Handlers orchestrate; services own the logic. 150 LOC per handler file.

## Required pattern for every handler

```rust
use axum::{extract::State, Json};
use crate::{auth::AuthCtx, error::AppError, http::Valid, state::AppState};

pub async fn create_thing(
    State(state): State<AppState>,
    ctx: AuthCtx,                                  // identity + tenant, from the extractor
    Valid(Json(body)): Valid<Json<CreateThing>>,   // body LAST; validated at the boundary
) -> Result<Json<ThingOut>, AppError> {
    ctx.require("thing.create")?;                  // permission FIRST, before any query
    state.rate_limit.check(&format!("thing:{}", ctx.user_id), 60).await?;
    let thing = services::things::create(&state.db, &ctx, body).await?;
    Ok(Json(thing.into()))
}
```

## Conventions

- Identity is resolved in ONE place. An auth middleware
  (`middleware::from_fn_with_state`) reads the session cookie or API
  key, builds an `AuthCtx`, and inserts it with `req.extensions_mut()`.
  The `AuthCtx` extractor (`FromRequestParts`) reads it back and rejects
  with 401 if absent. Handlers never parse tokens.
- Routes that bypass auth (health, webhooks, cron) live in a separate
  `Router` that is merged WITHOUT the auth layer, say so in a comment,
  and carry their own gate: timing-safe signature check for webhooks, a
  shared secret plus a platform header for cron.
- Tenant ID comes from `ctx`. Never from the body, the path, the query,
  or a header.
- The body extractor consumes the request, so `Json<T>` is the last
  argument. Wrap it in the validating extractor (`validator` or `garde`
  behind `Valid<T>`) so a malformed body never reaches a service.
- Errors are one enum in `src/error.rs` with `impl IntoResponse`,
  mapped to a status and a stable shape
  `{ "error": { "code": "...", "message": "..." } }`. `sqlx::Error`
  and `anyhow::Error` convert to `AppError::Internal`, which logs the
  source and shows the client a generic message.
- `GET` never writes. Caches, prefetchers, and link previews replay it.
- Limits are tower layers on the router, not per-handler code:
  `DefaultBodyLimit::max(..)` (axum's default is 2 MB),
  `tower_http::timeout::TimeoutLayer` (answers 408 by itself),
  `TraceLayer` with a request id, `CorsLayer` with an explicit origin
  list. `Router::layer` covers only routes added before it; build the
  router, then layer.
- Rate limit user-facing endpoints through the shared store. Metered
  endpoints (LLM, paid APIs) also assert a spend budget.
- axum 0.8 path params are `/{id}`; `/:id` was the 0.7 syntax.

## What NOT to do

- No `unwrap()` / `expect()` on request data. A panic drops the
  connection (500 only behind `CatchPanicLayer`) and with
  `panic = "abort"` in the release profile it takes the process.
- No `sqlx` calls in a handler. Handlers call services.
- No `Extension<T>` for shared state. `State<AppState>` (with `FromRef`
  for sub-state) fails at compile time when missing; `Extension` fails
  at request time.
- No financial table writes from a handler. Go through the money
  services; they enforce the invariants a raw write bypasses.
- Do not add a route to the unauthenticated router without adding it to
  the lint contract and the docs. Every allowlist, or none.

## Money paths require extra care

Routes that touch financial state include a `regression=pass` line in
the Senior-Checklist trailer, a test under `tests/` for the happy and
failure paths that `cargo test` runs, and error-reporter capture of
any rollback path.
