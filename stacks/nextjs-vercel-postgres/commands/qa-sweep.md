---
description: Sweep a deployed target for bugs with the QA sandbox member login, deterministic layer first, then an exploratory browser pass
argument-hint: [staging | url | blank = prod]
---

Run a QA sweep per the canonical brief in `QA-SWEEP.md` at the repo
root. Read that file FIRST and obey its boundaries exactly (member
login only, no file deletions if blob storage is shared with prod, no
outbound sends unless explicitly requested, QA sandbox tenant only).

Argument: `$ARGUMENTS` (empty = prod, `staging` = current staging
alias, or an explicit URL).

1. Pre-flight per the brief: confirm no deploy is rolling (latest CI
   run complete, newest deploy older than ~15 minutes). If one is, say
   so and wait or stop.
2. Run the Layer 1 deterministic sweep from the brief with the QA
   credentials from the env file (locally, or by dispatching the
   `qa-sweep.yml` workflow with `gh workflow run` in the remote-heavy
   model). Report pass/fail with the failure list verbatim.
3. Run the Layer 2 exploratory circuit from the brief using browser
   tools. Spend effort proportional to what changed recently
   (`git log --oneline -10` for hints on where to dig).
4. Produce the report in the brief's format: findings ordered by
   severity with reproduction evidence. If everything is clean, say so
   plainly and list what was covered. Where a finding maps to a flow
   worth protecting permanently, propose the scripted spec to add.
   A killed or partial run yields NO verdict; never report CLEAN from
   one.
