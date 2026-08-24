---
paths:
  - "**/app/api/**"
  - "**/app/routers/**"
  - "**/src/*/api/**"
---

<!-- SETUP (python-fastapi-postgres): adapt the helper names to your project.
Replaces the core `api-boundary.md` when installed; keep one, never both. -->

# API routes

One router per domain (`app/api/<domain>.py`), each an `APIRouter` with
its own prefix and tags, included once in `app/main.py`. Dependencies
live in ONE module, `app/api/deps.py`.

## Required pattern for every route

```python
from typing import Annotated

from fastapi import APIRouter, Depends, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import AuthContext, get_auth_context, get_session, rate_limit
from app.core.access import require_permission
from app.schemas.things import ThingCreate, ThingOut
from app.services import things

router = APIRouter(prefix="/things", tags=["things"])

@router.post("", response_model=ThingOut, status_code=status.HTTP_201_CREATED)
async def create_thing(
    body: ThingCreate,
    ctx: Annotated[AuthContext, Depends(get_auth_context)],
    session: Annotated[AsyncSession, Depends(get_session)],
) -> ThingOut:
    # Permission check FIRST. Tenant scoping is implicit in ctx.
    require_permission(ctx, "things.create")
    await rate_limit(f"things:{ctx.user_id}", max_requests=60, window_s=60)
    async with session.begin():
        thing = await things.create(session, ctx, body)
    return ThingOut.model_validate(thing)
```

## Conventions

- `get_auth_context` is the ONE resolver (session cookie and
  `Authorization: Bearer <api-key>` both land in the same `AuthContext`).
  It raises `HTTPException(401)` from inside the dependency, before the
  body is validated, so an unauthenticated caller sees 401, not 422.
- `require_permission(ctx, "thing.do")`, not membership. Tenant and
  owner IDs come from `ctx`, never from the body, query, or headers.
- Pydantic models at the boundary: request models set
  `model_config = ConfigDict(extra="forbid")`; every route declares
  `response_model` (or a return annotation) so an ORM object never
  serializes by accident. Output models set `from_attributes=True`.
- Errors go through the shared shapes: raise `DomainError` subclasses
  in services, map them once with exception handlers in `app/main.py`.
  Never let a `SQLAlchemyError` or `IntegrityError` reach the client.
- Rate limit user-facing endpoints through the shared store; model
  endpoints additionally assert a spend budget.
- `GET` never writes. A cache, a prefetch, or a link preview replays it.
- The route owns the transaction boundary (`session.begin()`); the
  service owns the logic. A route over 150 LOC is a service in disguise.
- Cron, webhook, and public-token routes bypass the resolver and say so
  in a comment: shared secret plus platform header for cron,
  `hmac.compare_digest` over the raw body for webhooks, hashed-token
  lookup for public links.

## What NOT to do

- Do not declare `tenant_id` on a request model. Access-control bypass.
- Do not put `select()` calls in a router module. Queries belong in
  services; the router passes `session` and `ctx` through.
- Do not `except Exception` in a route and return 200 with an error
  string. Let the handler map it.
- Do not run blocking work in an `async def` route (a sync driver,
  `requests`, `time.sleep`): use the async driver and `httpx.AsyncClient`,
  or declare the route `def` so FastAPI runs it in the threadpool.
- Do not write to financial tables from a route; go through the money
  services. Do not add a public path to the auth middleware allowlist
  without also adding it to the contract test (and vice versa).

## Money paths require extra care

A `regression=pass` line in the Senior-Checklist trailer; a test that
exercises both the happy and failure paths, collected by pytest (a file
without the `test_` prefix never runs); error-reporter capture of any
silent rollback.
