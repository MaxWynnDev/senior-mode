---
description: Multi-agent pre-push review. Fans out up to 6 parallel audits against the current diff and aggregates into one report.
---

GOAL: run the relevant review agents against the current diff, in
parallel, and aggregate one report with a single overall verdict.

Run before pushing any non-trivial change. Informational only. The hard
gate still lives in `.senior-mode/hooks/pre-push-checklist.sh` (Senior-
Checklist trailer) and CI. This command is the softer layer: catch
classes of issue those gates do not look for.

The specialist audits run on the dedicated subagents in
`.senior-mode/reviewers/`; each carries its own checklist, so the prompts below
stay thin.

## Step 1: Identify the diff

Same fallback as `/review`:

1. `git diff origin/<mainline>...HEAD` (committed ahead of the deploy branch)
2. `git diff --staged` (staged but uncommitted)
3. `git diff HEAD~1 HEAD` (last commit alone)

Also collect the changed file list with `git diff --name-only ...`. If
nothing matches, print `no diff to audit` and stop.

## Step 2: Decide which audits to run

Always run:

1. **A1 code-review.** General bug, regression, security pass against
   the full diff.
2. **A2 conventions sweep** (`conventions-sweeper`). Brand casing,
   punctuation in user-facing copy, date-helper usage, LOC budget,
   code-quality bar, orphaned tests, across the full changed list.

Run conditionally:

3. **A3 tenant isolation + sensitive data** (`tenant-isolation-reviewer`).
   Run only if at least one changed file is a route, service, or
   auth/ACL library. Audit those files only.
4. **A4 prompt audit** (`prompt-auditor`). Run only if at least one
   changed file is an LLM call site. Detection: for each changed source
   file, grep its current content (not the diff) for the Anthropic SDK
   import OR `api.anthropic.com` (some call sites hit the REST API
   through a fetch wrapper without importing the SDK). Audit the
   matches only.
5. **A5 money-path audit** (`money-path-reviewer`). Run only if at
   least one changed file path or its content matches your money
   domain (payments, payouts, billing, invoices, refunds, balances,
   ledgers, spend metering). When in doubt (a shared service that
   money paths call into), run it.
6. **A6 migration audit** (`migration-reviewer`). Run only if at least
   one changed file is a migration, a schema file, or the canonical
   seed-schema definition.

If A3 to A6 is skipped, still emit a `skipped, no matching files` line
in the final report so the human sees you considered it.

## Step 3: Fan out in parallel

Spawn every chosen audit in a single assistant message with multiple
Agent tool calls. Sequential audits defeat the purpose. Delete or
comment out any agent your project removed during kickoff.

**A1**: use a code-review subagent if one is registered (check the
session's available agent types; the `feature-dev:code-reviewer` plugin
agent or the bundled `/code-review` skill); otherwise fall back to
`general-purpose` with this prompt:

> Review this diff. Check for: PROMPTING.md violations,
> ENGINEERING-PRINCIPLES.md violations, obvious bugs, money-path
> safety, user-facing copy / brand issues. Report only HIGH confidence
> findings you verified by reading the code, grouped by severity, each
> with the concrete failure scenario. End with a one-line verdict:
> CLEAN, MINOR, NEEDS REVIEW, or BLOCKER. Diff source: `<source>`.
> Diff: `<diff body>`.

**A2 to A6** (each to its named subagent):

> Review these changed files per your checklist. Diff source:
> `<source>`. Files: `<matching changed files>`.

## Step 4: Aggregate

Single markdown report. No preamble, no closing summary beyond the
verdict line. Where two audits report the same finding, keep it once
under the more specific audit.

```
# Pre-push audit: <branch> @ <short-sha>

Diff source: <source>. Files: <N>. +<adds>/-<dels>.

## A1 code-review: <verdict>
## A2 conventions sweep: <verdict>
## A3 tenant isolation + sensitive data: <verdict or "skipped, no matching files">
## A4 prompt audit: <verdict or "skipped, no matching files">
## A5 money-path audit: <verdict or "skipped, no matching files">
## A6 migration audit: <verdict or "skipped, no matching files">
<findings under each>

## Overall: <verdict>
<one-line reason>
```

Overall verdict mapping (worst wins):

- BLOCKER if any audit returned BLOCKER, CRITICAL, or DO NOT APPLY.
- NEEDS REVIEW if any returned NEEDS REVIEW, NEEDS WORK, GAPS, or
  NEEDS CHANGES.
- MINOR if any returned MINOR.
- CLEAN otherwise (all-skipped counts; SAFE TO APPLY and READY map to
  CLEAN).

## Step 5: Do not push

STOP CONDITION: the aggregated report is printed. This command never
invokes `git push`. The human reads the report and decides: push as-is,
amend, fix forward, split the diff, or add a declared LOC exception.
The next `git push` still has to clear `pre-push-checklist.sh`
(Senior-Checklist trailer) and CI.
