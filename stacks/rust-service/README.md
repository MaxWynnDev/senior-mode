# Stack profile: rust-service

A Rust HTTP service packaged as an overlay: axum on tokio, sqlx with
compile-time checked queries, Postgres, shipped as a container image.
Install with `bash install.sh --profile rust-service <repo>`, or copy
the pieces by hand. Nothing here is required by the core kit; a project
on another stack skips this folder entirely (see `../../STACK.md`).

## What it assumes

- Rust stable, 2021 or 2024 edition, pinned by `rust-toolchain.toml`
  with `rustfmt` and `clippy` components.
- axum on tokio (multi-thread runtime), tower / tower-http layers for
  timeouts, body limits, tracing, CORS.
- sqlx with the `postgres` feature and the `query!` macros, plain SQL
  migrations under `migrations/` driven by `sqlx-cli`, the `.sqlx/`
  query cache committed so Docker and CI build with `SQLX_OFFLINE=true`.
- Postgres in every environment; a local container for dev, a service
  container in CI, a managed instance in prod.
- `cargo test` with `#[sqlx::test]` for database tests; rustfmt and
  clippy with `-D warnings` as the lint gate; `cargo deny` or
  `cargo audit` optional.
- A multi-stage Dockerfile; the image tagged with the git SHA; deploy
  by image to Fly.io, Cloud Run, or Kubernetes; GitHub Actions for CI.
- A single crate. A workspace works if you add `--workspace` to the
  cargo commands in `profile.json` and `cargo sqlx prepare`.

## What's in the overlay

| Path | Installs as | Purpose |
|---|---|---|
| `rules/api-routes.md` | path-scoped rule (location depends on the agent adapter) | axum handler contract: auth extractor, validated `Json<T>`, typed errors, tower limits |
| `rules/database.md` | path-scoped rule (location depends on the agent adapter) | `query!` macros, tenant filters, transactions, `FOR UPDATE`, sqlx migrations, `.sqlx` cache |
| `rules/services.md` | path-scoped rule (location depends on the agent adapter) | executor-generic services, `thiserror` enums, redaction before logs and models |
| `rules/scripts.md` | path-scoped rule (location depends on the agent adapter) | `src/bin/*` tools and `scripts/`, dry-run and prod-refusal conventions |
| `WORKFLOW.md` | repo root | the concrete pipeline (replaces the core template) |

The profile's rules REPLACE the core's `api-boundary.md`,
`data-layer.md`, `services.md`, and `scripts.md`. The kickoff asks you
to keep one of each pair so they never disagree. There is no UI rule;
delete the core `ui.md` for a pure service.

## Platform notes worth knowing

- sqlx macros check every `query!` against a live database at compile
  time through `DATABASE_URL` (read from the environment or a `.env` in
  the crate root). `cargo sqlx prepare` writes the check results to
  `.sqlx/`; with `SQLX_OFFLINE=true`, or when `DATABASE_URL` is unset,
  the macros read that cache instead. Commit `.sqlx/`, run
  `cargo sqlx prepare --check` in CI, and set `SQLX_OFFLINE=true` in the
  Docker builder stage. A stale cache fails compilation, which is the
  point.
- axum extractors run in argument order and the body extractor
  (`Json<T>`, `Form<T>`, `Bytes`) consumes the request, so it goes last.
  Shared state is `State<S>` (with `FromRef` for sub-state) and is
  checked at compile time; `Extension<T>` is checked at request time.
  Custom extractors implement `FromRequestParts`; that is where the
  auth context belongs. axum 0.8 path params are `/{id}`.
- `Router::layer` wraps the routes added BEFORE it; routes added after
  are not covered. Build the router, then layer. Inside a
  `tower::ServiceBuilder`, layers listed first run outermost.
  `tower_http::timeout::TimeoutLayer` answers 408 by itself;
  `tower::timeout` needs `HandleErrorLayer`. axum's default body limit
  is 2 MB; change it with `DefaultBodyLimit::max`.
- `#[tokio::main]` is the multi-thread runtime; `#[tokio::test]` is
  `current_thread` unless you say otherwise, so a test can pass while
  prod deadlocks on a blocking call. Anything that blocks (password
  hashing, big serialization, sync clients) goes through
  `tokio::task::spawn_blocking`.
- Rust 1.85 and later ship the 2024 edition; `cargo fix --edition`
  migrates.
- Enable the `rust-analyzer` LSP plugin for symbol-aware navigation.

## Install by hand

1. Rules: copy `rules/*.md` to where your agent adapter keeps
   path-scoped rules, and add the `paths:` frontmatter each file's
   SETUP comment shows.
2. Docs: `WORKFLOW.md` to the repo root; fill the `<...>` slots.
3. Commands: copy the `commands` block from `profile.json` into the
   agent's project instructions so `/go` and `/iterate` know the
   oracle.
4. Runner: create `scripts/migrate-prod.sh` with the properties listed
   in `WORKFLOW.md` (Migrations). Never point `sqlx migrate run` at
   prod without it.
5. CI: a workflow that runs fmt, clippy, `cargo sqlx prepare --check`,
   `sqlx migrate run` + `cargo test` against a Postgres service
   container, then builds and pushes the image tagged with the SHA.

## What to adapt if you use actix-web or diesel

- actix-web: state is `web::Data<T>` and the body is `web::Json<T>`
  (limit via `JsonConfig::limit`); errors implement `ResponseError`
  instead of `IntoResponse`; middleware is `wrap` / `from_fn`. The
  database and services rules apply unchanged.
- diesel: schema comes from `diesel print-schema` into `schema.rs`,
  migrations are `diesel migration generate|run|revert` with `up.sql`
  and `down.sql` per folder and the `__diesel_schema_migrations`
  table, and queries are checked by the DSL rather than a cache, so
  drop the `.sqlx` signals and the prepare step. diesel is synchronous:
  use `diesel-async` or `spawn_blocking` from axum handlers.
