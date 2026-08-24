---
paths:
  - "**/views.py"
  - "**/views/**"
  - "**/api/**"
  - "**/serializers.py"
---

<!-- SETUP (django-postgres): the `paths:` frontmatter above scopes this
rule (add `**/routers.py` for Ninja); adapters that ignore frontmatter
map the same globs in their own config. Adapt helper names to your
project. Replaces the core `api-boundary.md` when installed; keep one. -->

# API routes (views, DRF viewsets, Ninja routers)

Versioned API surface under `/api/v1/`. One module per resource.

## Required pattern for every endpoint

```py
class ThingViewSet(viewsets.ModelViewSet):
    permission_classes = [IsAuthenticated, require_permission("thing.do")]
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "thing"
    serializer_class = ThingSerializer

    def get_queryset(self):
        # request.tenant is set by TenantMiddleware from the user's membership.
        return (Thing.objects.filter(tenant=self.request.tenant)
                .select_related("owner").prefetch_related("tags"))

    def perform_create(self, serializer):
        create_thing(tenant=self.request.tenant, actor=self.request.user,
                     **serializer.validated_data)
```

The Ninja form is the same contract: `Router(auth=SessionOrApiKey())`,
a `Schema` for the payload, `request.auth` for the caller, one service
call. A plain view uses `@require_POST` or `@require_safe` plus `@login_required`.

## Conventions

- ONE auth resolver: a single authentication class (DRF) or Ninja
  `auth` callable that accepts a session cookie and an API key, set
  globally in `DEFAULT_AUTHENTICATION_CLASSES` or on the `NinjaAPI`.
  Never a per-view session lookup.
- Permission FIRST, then rate limit, then parse. `IsAuthenticated` is
  membership; `require_permission("thing.do")` is the check.
- Serializers (or Ninja `Schema`s) validate at the boundary with
  `is_valid(raise_exception=True)`. `tenant` and `owner` are
  `read_only_fields`. No `fields = "__all__"`.
- Tenant comes from `request.tenant`, resolved by middleware from
  `request.user`'s membership. No membership resolves to `None` and a
  403; never fall back to the first tenant.
- Handlers orchestrate; services own the logic. `perform_create`,
  `perform_update`, and action bodies are one service call.
- Error shape comes from the project `EXCEPTION_HANDLER` (or Ninja
  exception handlers): `{"detail": ...}` for every failure. Never raw
  `IntegrityError` or `ValidationError` text.
- `GET` never writes. A cache, a prefetch, or a link preview replays
  it. Side effects live under `@action(methods=["post"])`.
- Lists declare `select_related` for every FK the serializer reads and
  `prefetch_related` for every M2M or reverse FK, paginate through
  `DEFAULT_PAGINATION_CLASS`, and carry a `django_assert_num_queries`
  test whose count does not grow with page size.

## What NOT to do

- Do not accept the tenant ID from the body, query string, or a
  header. Access-control bypass.
- Do not `@csrf_exempt` a session-authenticated view to make a client
  work. Webhooks are exempt AND verify a signature with
  `hmac.compare_digest`; crons gate on a shared secret plus a platform
  header.
- Do not query before the permission check. DRF runs
  `check_permissions` before `get_queryset`; keep custom views in the
  same order.
- Do not write to financial tables from a view. The money services
  enforce invariants a raw `save()` bypasses.
- Do not add a public URL to the auth middleware's exempt list without
  also adding it to the lint contract and the docs. Every allowlist,
  or none.

## Money paths require extra care

Endpoints that touch financial state should include a `regression=pass`
line in the Senior-Checklist trailer, a test for both the happy and
failure paths that the runner collects, and error-reporter capture of
any silent rollback.
