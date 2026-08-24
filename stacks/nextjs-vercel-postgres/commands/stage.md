---
description: Stage the working tree on demand (copy-on-write DB branch off prod + preview deploy), or tear staging down
argument-hint: [migrate | down]
---

Stage the current working tree against a copy-on-write branch of prod
data, or tear staging down. Uses the stage scripts from the kit's
reference-stack QA pack (install them as `scripts/stage-*.mjs` plus
package.json `stage:up` / `stage:down`). Argument: `$ARGUMENTS` (empty,
`migrate`, or `down`).

If the argument is `down`:

1. Run `pnpm stage:down` and show the dry-run list.
2. If branches are listed, run `pnpm stage:down --apply` and confirm
   each deletion in the output.

Otherwise (stage up):

1. Show `git status --short` and `git log --oneline -1` so it is clear
   exactly what working tree is being staged (stage-up deploys the
   working tree, not HEAD).
2. If the argument is `migrate`, summarize the migrations on disk that
   are not yet applied, since they will be rehearsed against the
   branch.
3. Run `pnpm stage:up` (add `--migrate` when the argument is
   `migrate`). Stream the output; the build takes several minutes.
4. If it fails on a missing branching-API key, relay the one-time
   setup instructions from the script verbatim and stop.
5. When it succeeds, report: the staging URL, the branch name, and the
   live-wire caveats from the script summary (real tokens in branched
   data, shared blob store). Remind that teardown is `/stage down`.
