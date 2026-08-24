---
description: Audit a route or service file for tenant-isolation coverage (explicit tenant filters and, where used, the database isolation wrapper)
argument-hint: <path/to/route or service file>
---

Audit the file at $ARGUMENTS for tenant-isolation coverage. Required
reading first: `.senior-mode/rules/data-layer.md` (the tenant-wrapper
pattern) and your wrapper's implementation (e.g. `db/with-tenant.ts`),
if one exists.

Context: if database-level row isolation (Postgres RLS or equivalent) is
enabled, or will be, on every table with a tenant key, then any query
NOT wrapped in the tenant helper returns zero rows silently once
enforcement turns on. Even without it, an unwrapped query that does not
filter by tenant is a cross-tenant leak. This audit catches both.

For the target file:

1. List every DB query (anything calling `db.select`, `db.insert`,
   `db.update`, `db.delete`, `db.execute`, `db.transaction`, or the
   equivalents in your data layer). Skip `tx.*` calls inside an
   existing tenant-wrapper block.

2. Classify each top-level query:
   - **WRAPPED**: inside the tenant helper.
   - **UNWRAPPED**: bare `db.*` call with no tenant guard above it.
   - **EXEMPT**: documented exception (cross-tenant admin query,
     public-token route, system table). The exemption MUST have a
     comment explaining why. No comment, treat as UNWRAPPED. A
     privileged bypass helper inside an ordinary per-tenant handler is
     a finding, not an exemption.

3. For each UNWRAPPED query, report:
   - File and line range
   - Table(s) touched
   - Whether each table has a tenant key (check the schema). If yes,
     the unwrapped query is debt that leaks or goes silent under
     enforcement. If no (e.g. `users`, internal bookkeeping), the lack
     of wrapping is fine.
   - Whether the query's failure could be silent (inside a swallowing
     try/catch): a silent non-write on a money table is CRITICAL.
   - The minimal wrapping change

4. Cross-check auth: does the file go through the auth resolver, or is
   its route in your public-route allowlist? If neither, flag a
   separate auth gap (different bug class, same audit pass). Does any
   GET handler write? Flag it.

4a. Note delegations: if the file calls service functions instead of
    touching `db` directly, list each delegated call once and flag
    "audit `<file>` separately." Do not chase into the service file in
    this run.

5. Output a markdown table with columns: `lines`, `status`, `table`,
   `tenant-keyed`, `fix`. End with a one-line verdict: CLEAN, GAPS, or
   CRITICAL.

Do not modify the file. Read-only audit.
