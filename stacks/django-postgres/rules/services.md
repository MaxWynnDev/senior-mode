---
paths:
  - "**/services.py"
  - "**/services/**"
  - "**/selectors.py"
---

<!-- SETUP (django-postgres): the `paths:` frontmatter above scopes this
rule; adapters that do not read frontmatter map the same globs in their
own config. Adapt the helper names to your project. Replaces the core
`services.md` when installed; keep one. -->

# Services

The business-logic layer: `apps/<domain>/services.py` writes,
`apps/<domain>/selectors.py` reads. Views, management commands, and
tasks call these; nothing else calls `save()` on a tenant-owned model.

## Conventions

- Every service takes `tenant` and `actor` as its first keyword
  arguments and filters on the tenant. Never query without it; never
  derive the tenant from the object being edited.
- Access-control helpers live in ONE module (`<apps/access/rules.py>`):
  `can_access_thing(actor, thing)` and the queryset variants
  (`things_visible_to(actor)`) for list filtering. Tenant scoping alone
  is not per-record visibility.
- Transactions are explicit in the service, not in the view:
  `with transaction.atomic(using=alias):` around every multi-table
  write, `transaction.on_commit()` for anything that leaves the
  process. Accept a `using` alias (default `"default"`) so a caller can
  compose several services into one atomic write; nested `atomic()`
  blocks become savepoints.
- Services return model instances or typed dataclasses, never dicts
  and never a `Response`.
- No signals for business logic. A `post_save` receiver is a writer
  nobody greps for. Call the second service from the first.
- Sensitive fields (SSN, bank, anything regulated) are filtered
  through the canonical set (`<core/sensitive.py: SENSITIVE_FIELDS>`)
  before they reach a log line, the error reporter, an export, a
  third party, or a model prompt. `@sensitive_variables` on the
  function that handles them keeps them out of tracebacks; the
  logging filter and the reporter's `before_send` use the same set.
  A new sensitive column adds itself to the set in the same commit.
- Tool handlers that a model can call receive the full actor context
  (`tenant`, `actor`, permissions), not bare ids, so per-record access
  checks still apply inside the tool.
- A guard on one write path is not immutability. Before claiming a
  column "never changes", grep every writer: `update()`, cascades,
  admin actions, management commands, and data migrations.

## Adding an LLM-powered service

Read `PROMPTING.md` at repo root first, then copy your most thorough
existing call site:

- A pure prompt module (`<name>_prompt.py`): system prompt constant,
  user-prompt builder (today's date passed in, never read inside), a
  validator for the parsed output. No Django imports; the eval harness
  imports it without `django.setup()`.
- The shell (`<name>_service.py`): spend-budget assertion before the
  call, retry on 408 / 429 / 5xx, spend record after, persistence
  inside `atomic()`.
- Model ID from the one config module; the pricing table knows it.

The kit's new-feature slash command scaffolds this skeleton.

## Size

400 LOC per new file (ENGINEERING-PRINCIPLES.md section 12a).
Orchestration modules may carry a declared 800 LOC tolerance. A feature
that adds more than 50 lines to a file already over budget triggers a
split-first commit: `services.py` becomes a `services/` package with
one module per verb group.
