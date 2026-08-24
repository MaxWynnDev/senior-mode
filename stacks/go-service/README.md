# Stack profile: go-service

A Go HTTP service (or worker) over Postgres, shipped as a container
image, packaged as an overlay. Install with `bash install.sh --profile
go-service <repo>`, or copy the pieces by hand. Nothing here is required
by the core kit; an existing project on another stack skips this folder
entirely (see `../../STACK.md`).

## What it assumes

- Go 1.22 or newer with modules; one binary per `cmd/<name>`; private
  code under `internal/`.
- `net/http` with the 1.22 `ServeMux` (method + pattern routes), or chi
  when you want middleware groups and sub-routers. Everything below
  works with either.
- Postgres through pgx v5 (`pgxpool`), sqlc for typed queries generated
  from plain SQL files. `database/sql` works with the same rules; you
  lose pgx-native types and the `pgx.Tx` API.
- goose for SQL migrations (atlas is the documented alternative), run
  from a terminal through a confirmation-gated wrapper, never by the
  deploy.
- `go test` with the race detector; testify's `require` if you want it.
- gofmt (or goimports) plus golangci-lint.
- A multi-stage Dockerfile producing a static binary on a distroless or
  scratch base; the image is built once in CI and deployed by reference
  to Fly.io, Cloud Run, or Kubernetes.
- GitHub Actions CI; a CI-gated deploy of the exact SHA that passed.
- `log/slog` for structured logs; an error reporter with release = git
  SHA.

## What's in the overlay

| Path | Installs as | Purpose |
|---|---|---|
| `rules/api-routes.md` | path-scoped rule (location depends on the agent adapter) | handler contract: identity in context, bounded decode, server timeouts, no writes in GET; scoped to `**/internal/http/**` and friends |
| `rules/database.md` | path-scoped rule (location depends on the agent adapter) | sqlc queries, tenant predicate, `pgx.Tx`, money as `int64`, goose migrations; scoped to `**/db/**`, `**/migrations/**`, `**/queries/**` |
| `rules/services.md` | path-scoped rule (location depends on the agent adapter) | business-logic layer: `ctx` + `Querier` signatures, `%w` wrapping, slog redaction; scoped to `**/internal/service/**` |
| `rules/scripts.md` | path-scoped rule (location depends on the agent adapter) | `cmd/tools/*` vs `scripts/`, `-apply`, prod refusal, child env allowlist; scoped to `**/cmd/tools/**` and `**/scripts/**` |
| `WORKFLOW.md` | repo root | the concrete pipeline (replaces the core template) |
| `profile.json` | read by the installer and the kickoff | real commands and layout globs for this stack |
| `detect.txt` | read by `stacks/detect.sh` | signals that pick this profile from a repo |

The profile's rules REPLACE the core's `api-boundary.md`,
`data-layer.md`, `services.md`, and `scripts.md`. Delete the core
`ui.md`; a Go service has no UI layer for it to scope to. The kickoff
asks you to keep one of each pair so they never disagree.

## Platform notes worth knowing (as of mid-2026)

- Go 1.22 `ServeMux` routes on method and pattern:
  `mux.HandleFunc("GET /v1/items/{id}", h)`, read with
  `r.PathValue("id")`. `{path...}` matches the rest of the URL, `{$}`
  matches only the exact path. The most specific pattern wins;
  conflicting patterns panic at registration, which is a feature: your
  route test catches it before a deploy does.
- Context propagation is the whole concurrency story. `r.Context()` is
  cancelled when the client disconnects or the server shuts down; pass
  it into every pgx call, HTTP client call, and goroutine. Never store
  a `context.Context` in a struct. Detached work uses
  `context.WithoutCancel` (Go 1.21) and says why.
- `pgxpool`: one pool per process, created once in `main` with
  `pgxpool.New(ctx, url)` and closed on shutdown. `MaxConns` defaults to
  the greater of 4 and `runtime.NumCPU()`; set it explicitly and keep
  `MaxConns` times replica count under the Postgres connection cap.
  `pool.Ping(ctx)` at boot is your readiness probe.
- sqlc compiles `.sql` files into typed Go at generate time and checks
  them against your schema, so a renamed column fails `sqlc generate`
  (or `sqlc vet`) instead of a request. The generated `Queries` type
  wraps a `DBTX` interface satisfied by both the pool and a `pgx.Tx`;
  `emit_interface: true` also emits a `Querier` interface that services
  accept and tests fake. Commit the output; `sqlc diff` in CI proves it
  is current.
- goose stores applied versions in `goose_db_version` and runs each
  file in its own transaction. `goose create` mints timestamp versions;
  `goose fix` renumbers them to sequential so mainline stays strictly
  increasing and you never need `-allow-missing`. Postgres DDL is
  transactional, except `CREATE INDEX CONCURRENTLY`, which needs
  `-- +goose NO TRANSACTION`.
- atlas instead of goose: versioned SQL files plus an `atlas.sum`
  checksum committed alongside them, `atlas migrate lint` in CI against
  a dev database, and `atlas migrate apply` as the runner. The gating
  rules in `WORKFLOW.md` are identical; only the command changes.
- golangci-lint v2 uses a `version: "2"` config file and a different
  linter section layout than v1; pin the version in CI and locally so
  a lint diff is a code diff, not a tool diff.
- `go test -race` is the default `test` command here, not an extra.
  Data races that pass without it are still bugs.
- Enable a gopls-based language server plugin for symbol-aware
  navigation if your agent adapter supports one.

## Install by hand

1. Rules: copy `rules/*.md` into your agent's rules location and keep
   the `paths:` frontmatter (or the adapter's equivalent) so each loads
   only when its files are touched.
2. Docs: `WORKFLOW.md` to the repo root; fill in the `<...>` markers
   (service name, registry, deploy target).
3. Commands: copy the `commands` block of `profile.json` into your
   Makefile or the agent's project instructions file so `/go`, `/ship`,
   and the app-verifier run the real thing.
4. Write `scripts/migrate-prod.sh` per the "Migrations" section of
   `WORKFLOW.md` before the first production migration.
5. Add `/healthz` (process up, reports the build SHA) and `/readyz`
   (`pool.Ping`) before the first deploy; every target in `WORKFLOW.md`
   probes them.

## What to adapt if you use gin/echo/GORM

- gin: the handler contract holds; identity goes in `c.Request.Context()`
  (not `c.Set`) so services stay framework-free, and `c.ShouldBindJSON`
  replaces `decode`. Keep `http.MaxBytesReader` on `c.Request.Body`.
- echo: same as gin with `c.Request().Context()` and `c.Bind`; register
  the auth and recover middleware with `e.Use` before any group.
- GORM: `database.md` assumes sqlc; keep the tenant predicate, the
  transaction-passing rule (`*gorm.DB` from `db.Begin()` takes the place
  of `pgx.Tx`), and the money rules verbatim. Treat `Raw` and `Exec`
  strings as the unchecked cast the rule describes.
