---
paths:
  - "**/internal/service/**"
  - "**/internal/services/**"
  - "**/internal/domain/**"
---

<!-- SETUP (go-service profile): the business-logic layer. Adapt the
package names (`db`, `auth`, `access`, `sensitive`) to your project.
Replaces the core `services.md` when installed; keep one. -->

# Services

The business-logic layer. Handlers call services; services own the
invariants. Some files here grow into god-files; watch the LOC budget.

## Shape

```go
// Charge is the only writer of invoices.paid_minor. Callers own the transaction.
func (s *Invoices) Charge(ctx context.Context, q db.Querier, ac auth.Context, in ChargeInput) (Invoice, error) {
	row, err := q.GetInvoiceForUpdate(ctx, db.GetInvoiceForUpdateParams{TenantID: ac.TenantID, ID: in.InvoiceID})
	if errors.Is(err, pgx.ErrNoRows) {
		return Invoice{}, ErrNotFound
	}
	if err != nil {
		return Invoice{}, fmt.Errorf("invoices.Charge: load %s: %w", in.InvoiceID, err)
	}
	// ...
}
```

## Conventions

- `ctx` first, then a `db.Querier` (satisfied by `db.New(pool)` and
  `db.New(tx)` alike), then the auth context. The caller decides the
  transaction boundary, so several service calls compose into one
  atomic write. A service opens its own `pool.Begin` only when it is
  the top-level orchestrator, and says so.
- Every service is tenant-scoped through `ac.TenantID`. Never a
  `tenantID` parameter a caller could fill from a request body.
- Access-control helpers live in ONE package (`internal/access`):
  `CanReadItem`, `CanEditItem`, and the SQL-predicate variants for
  list filtering. Tenant scoping alone is not per-record visibility.
- Errors: wrap with the operation and `%w`
  (`fmt.Errorf("invoices.Charge: %w", err)`); export sentinels
  (`ErrNotFound`, `ErrConflict`, `ErrForbidden`) that handlers map with
  `errors.Is`. Never `log.Fatal` or `os.Exit` outside `main`. A money
  write inside `if err != nil { log; continue }` is a defect: it will
  not 500, it will quietly not write.
- Never store `ctx` in a struct. Never `context.Background()` on a
  request path; detached work uses `context.WithoutCancel` with a
  comment saying who owns its lifetime.
- Goroutines a service spawns run under an `errgroup` bound to `ctx`
  with a concurrency limit. No fire-and-forget without a named owner
  and a bounded queue.
- Logging goes through the `*slog.Logger` pulled from `ctx`. Types that
  carry sensitive fields implement `slog.LogValuer` and return a
  redacted value; the handler in `main` also sets `ReplaceAttr` against
  the canonical key list in `internal/sensitive`, so a stray
  `slog.Any("user", u)` still redacts. The same list filters attributes
  before they reach a model prompt, a tool result, an export, or a
  third party.
- Tool handlers a model can call receive the full `auth.Context`, not
  bare `{TenantID, UserID}`, so per-record checks still apply inside
  the tool.
- A guard on one write path is not immutability. Before claiming a
  column "never changes", grep every writer: cascades, resyncs, cron
  binaries under `cmd/`, and `cmd/tools`.

## Adding a model-powered service

Read `PROMPTING.md` first, then copy your most thorough existing call
site. The prompt constant, the user-prompt builder (including today's
date from `clock.Now()` if relevant), and the post-parse validator live
in a PURE package with no `db` or `net/http` import, so the eval harness
can import them. The shell around it does the spend-budget assertion,
the call with retries on 408 / 429 / 5xx, the spend record, and
persistence. The kit's AI-feature scaffold command generates this
skeleton.

## Size

400 LOC per new file (ENGINEERING-PRINCIPLES.md section 12a).
Orchestration modules may carry a declared 800 LOC tolerance. A feature
that adds more than 50 lines to a file already over budget triggers a
split-first commit. Generated sqlc output is exempt; nothing else is.
