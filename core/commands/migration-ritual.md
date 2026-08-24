---
description: Walk through a production migration safely with pre-flight checks
---

Pre-flight a production migration. Do every step. Do not skip ahead.
Adapt the commands to your ORM and runner; WORKFLOW.md "Migrations"
names them. The reference stack's invocation is shown in brackets.

1. Confirm current branch and HEAD, and that HEAD is a descendant of
   the mainline (a stale worktree must not invoke an older runner):
   `git log --oneline -1`
   `git status --short`
   `git fetch origin && git merge-base --is-ancestor origin/<mainline> HEAD`

2. Verify no pending generations are uncommitted
   [`pnpm drizzle-kit check`, or your equivalent].

3. List migrations on disk vs migrations recorded in the journal
   [`ls <migrations-dir>/*.sql` and the journal tail]. If your journal
   carries timestamps, confirm the new entries are NEWER than the last
   applied one; a stale watermark (parallel sessions generating at
   once) is silently skipped by some runners.

4. For each migration NOT yet applied, read it and summarize:
   - File name + index
   - Is it additive (CREATE / ADD COLUMN / CREATE INDEX) or destructive
     (DROP / ALTER ... DROP)?
   - Approximate row touch (if estimable from the schema)
   - Locking risk on hot tables

5. Confirm the target points at prod. Print ONLY the host portion,
   never the full URL, and never write the URL to a file:
   [`node -e "console.log(new URL(process.env.DATABASE_URL).host)"`]
   If the app connects as a restricted role and migrations need the
   owning role, confirm the owner URL targets the SAME database.

6. Pause and ASK ME: ready to proceed?

If I say yes:

7. Run the sanctioned migration runner and stream the output. It
   should demand a typed confirmation (e.g. `APPLY`). I will type it
   directly into the terminal myself when prompted.

8. After migration completes, show the new journal tail and confirm
   the new entries landed.

If the migration fails partway, STOP. Do not retry blindly. Inspect the
error and the exact migration-table and schema state before deciding
between fix-forward and a point-in-time restore.

Do NOT run the migration without my explicit go-ahead at step 6.
