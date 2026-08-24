<!-- SETUP: stack-neutral rule for the business-logic layer. Scope it with
`paths:` frontmatter (e.g. "src/services/**", "app/services/**",
"internal/**"). Name your access-control module and sensitive-attribute
list where the brackets are. -->

# Services

The business-logic layer. Handlers call services; services own the
invariants.

## Conventions

- Every service is tenant-scoped. The first argument or the context
  object carries the tenant ID. Never query without it.
- Access-control helpers live in ONE module (`<lib/access>`):
  `canAccessX`, `canAccessY`, and the SQL-fragment variants for list
  filtering. Tenant scoping alone is not per-record visibility.
- Accept an optional transaction/executor parameter so a caller can
  compose several service calls into one atomic write.
- Sensitive attribute slugs (SSN, bank, anything regulated) are filtered
  through the canonical list (`<isSensitiveAttribute>`) before they
  reach a model, a log line, an export, or a third party.
- Tool handlers that a model can call receive full auth-context-shaped
  objects, not bare `{tenantId, userId}`, so per-record access checks
  still apply inside the tool.
- A guard on one write path is not immutability. Before claiming a
  column "never changes", grep every writer of it: cascades, resyncs,
  crons, and admin tools come through their own doors.

## Adding a Claude-powered service

Read `PROMPTING.md` first, then copy your most thorough existing call
site. Keep the prompt, builders, and validator in a PURE module (no DB
or framework imports) so the eval harness can import them; the shell
around it does the budget gate, the call, the retries, the spend record,
and persistence. `/new-claude-feature <name>` scaffolds this.

## Size

400 LOC per new file (ENGINEERING-PRINCIPLES.md section 12a).
Orchestration modules may carry a declared 800 LOC tolerance. A feature
that adds more than 50 lines to a file already over budget triggers a
split-first commit.
