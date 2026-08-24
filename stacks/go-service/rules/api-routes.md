---
paths:
  - "**/internal/http/**"
  - "**/internal/api/**"
  - "**/handlers/**"
---

<!-- SETUP (go-service profile: net/http 1.22 ServeMux or chi): adapt the helper
names (`auth`, `respond`, `decode`). Replaces the core `api-boundary.md`; keep one. -->

# HTTP handlers

Versioned API surface: one package per surface, one file per resource, every
route in one `routes.go` so the route test can list them.

## Required pattern for every handler

```go
func (h *Handler) createItem(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	ac, ok := auth.FromContext(ctx) // set by the ONE auth middleware
	if !ok {
		respond.Unauthorized(w)
		return
	}
	if !ac.Can("item.create") { // permission, not membership
		respond.Forbidden(w)
		return
	}
	var in CreateItemRequest // decode = MaxBytesReader + DisallowUnknownFields + in.Validate()
	if err := decode(w, r, &in); err != nil {
		respond.BadRequest(w, err)
		return
	}
	item, err := h.items.Create(ctx, db.New(h.pool), ac, in.ToInput())
	if err != nil {
		respond.Error(w, err) // maps sentinel errors; never leaks a pg error
		return
	}
	respond.JSON(w, http.StatusCreated, item)
}

mux.HandleFunc("POST /v1/items", h.createItem)  // method + pattern, Go 1.22
mux.HandleFunc("GET /v1/items/{id}", h.getItem) // r.PathValue("id")

srv := &http.Server{
	Addr:              ":8080",
	Handler:           chain(mux, requestID, recover, auth, ratelimit),
	ReadHeaderTimeout: 5 * time.Second,
	ReadTimeout:       15 * time.Second,
	WriteTimeout:      30 * time.Second,
	IdleTimeout:       60 * time.Second,
}
```

## Conventions

- Auth middleware FIRST. Identity lives in `context.Context` under an
  unexported key type; handlers read it with `auth.FromContext`. Never
  query data before it resolves.
- Tenant ID comes from the context, never from the body, query, or a header.
- `decode` wraps `http.MaxBytesReader(w, r.Body, 1<<20)`, sets
  `DisallowUnknownFields`, then validates; an oversized body is a 413.
- Per-record access helpers (`access.CanReadItem`) on top of tenant
  scoping. Rate limit user-facing endpoints through the shared store;
  metered (LLM, paid API) endpoints also assert a spend budget.
- `GET` never writes. Caches, prefetchers, and crawlers replay it.
- Handlers orchestrate; services own the logic. Over 150 LOC is a service in disguise.
- Every outbound call takes `ctx`. The request context cancels on client
  disconnect and on shutdown; pgx and `http.Client` honor it.

## What NOT to do

- Do not use bare `http.ListenAndServe`: no timeouts, no graceful stop. Build
  the `http.Server` above and call `Shutdown` on SIGTERM (`signal.NotifyContext`).
- Do not `panic` on bad input; return the shared error shape. Recover is for bugs.
- Do not return `err.Error()` from pgx or a service to the client.
- Do not bypass the auth middleware for "internal" routes. Cron and
  webhook handlers say so in a comment and carry their own gate: shared
  secret plus platform header, or `hmac.Equal` on the signature.
- Do not register a public route without adding it to the middleware
  allowlist AND the route test. Every allowlist, or none.

## Money paths require extra care

Financial state is written only through the money services, never from a
handler. Handlers that touch it include a `regression=pass` trailer line, a
test covering the happy and failure paths (run by `go test ./...`, not behind
a tag), and error-reporter capture of any silent rollback.
