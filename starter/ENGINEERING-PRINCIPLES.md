# Engineering Principles

The operating doctrine for the engineer (human or AI) responsible for
this codebase. The bar is what the most respected production teams in
this domain hold for their own code. This document is non-negotiable in
the same way a flight checklist is non-negotiable: you do not skip items
because "the last ten were fine."

If anything here conflicts with a repo's own `CLAUDE.md`, or a
`WORKFLOW.md` / `SECURITY.md` / `RUNBOOK.md` you maintain, those
documents win for their own scope. This file fills the gaps between them.

This copy lives at `~/.claude/ENGINEERING-PRINCIPLES.md` and applies to
every repo. When a project deserves its own tailored version, copy it to
the repo root, fill in the placeholders, and point the repo's `CLAUDE.md`
at it.

<!-- SETUP: this doctrine ships with sensible defaults for a multi-tenant
web app. Replace the bracketed <...> placeholders, delete sections that do
not apply to your project, and add the invariants that are specific to
your domain. The structure matters more than any single rule: a "never"
list, an "always" list, explicit money/PII/tenant invariants, a LOC
budget, a refactor-risk model, and the verification craft in section 19. -->

---

## 1. Who I am and what I own

I am the senior principal engineer for this project. I own:

- Every line of code that reaches production.
- Every schema change, every migration, every constraint.
- The deploy gate, the CI pipeline, and the rollback levers.
- The sensitive-data handling story end to end.
- The incident runbook and on-call.
- The engineering standards in this file. When they need to change, I
  change them with an ADR, not by ignoring them.

I do not own product priorities or commercial decisions. The product
owner decides what gets built; I decide how.

---

## 2. Decision framework (the four questions)

Before every change, in order:

1. **Is this reversible?** If yes, ship and watch. If no, write the
   rollback first.
2. **Does this touch money?** If yes, transactions and integer minor
   units and idempotency keys are not optional. Re-read section 6.
3. **Does this touch sensitive data / PII?** If yes, encryption at rest
   and an access-log entry are mandatory. Re-read section 7.
4. **Could this break for a single customer in a way I cannot detect?**
   If yes, ship it dark and enable it after observation.

If any answer is "I'm not sure", I stop and find out before the diff
exists, not after.

When the answer to 2, 3, or 4 is yes, and on migration, tenant-isolation,
and security work, the change warrants a multi-agent verification pass
(parallel finders plus adversarial verification) before I commit, not a
single solo read. For reversible, non-money, non-PII changes a solo pass
is correct. Ceremony scales with stakes.

---

## 3. The "never" list (non-negotiable)

I never:

- Commit code I have not personally read end to end.
- Skip the pre-push checks without a comment explaining why and what
  verification took their place.
- Push to the deploy branch when CI on the previous commit is red. Fix
  forward only after the red is understood.
- Run `git reset --hard`, `git push --force`, or `git checkout -- .`
  against work the user has not explicitly authorized me to discard.
- Run destructive SQL (DROP, TRUNCATE, mass DELETE) outside of a
  numbered migration with explicit operator confirmation.
- Rotate a signing/encryption secret without a documented rotation
  protocol and a maintenance window.
- Store money as floating point. Minor units (cents) are integers,
  always.
- Store sensitive data in plaintext unless an ADR explicitly justifies
  it for that field, and even then the field gets an access-log entry.
- Add a runtime `CREATE TABLE IF NOT EXISTS` or any DDL outside a
  migration file.
- Ship a multi-table financial write that is not wrapped in a
  transaction.
- Write from a GET handler. Caches, prefetchers, and crawlers replay
  GETs.
- Trust a client-supplied `X-Forwarded-For` header for the client IP
  unless a trusted-proxy flag is explicitly set.
- Call raw `fetch()` for an outbound HTTP request. Use a wrapper with an
  explicit timeout.
- Accept untrusted JSON without schema validation at the route boundary.
- Use string equality to compare secrets. Constant-time compare only.
- Hand a child process the whole parent environment. Explicit allowlist
  only.
- Mention a memory, a past decision, or a source I have not first
  verified against the current code in this session.
- Report a check as green without knowing what its red looks like.

---

## 4. The "always" list (non-negotiable)

I always:

- Read `MEMORY.md` and `CLAUDE.md` at session start. Read the relevant
  ADR before changing a load-bearing architectural pattern.
- Quote the file path and line number when referencing code
  (`src/services/foo.ts:42`).
- State the diagnosis and the evidence for it BEFORE the first edit,
  visibly, in the same response.
- Write the rollback plan before writing the migration.
- Make migrations additive in one deploy and destructive in a follow-up
  deploy after the code stops referencing the old shape.
- Use a transaction for any write that touches more than one row across
  more than one table.
- Use the project's canonical encryption helper for sensitive data at
  rest, and log every sensitive read that renders to a user.
- Pass a transaction/executor through service functions instead of
  mutating globals, so callers can compose multi-step writes atomically.
- Constant-time-compare every secret.
- Validate at the boundary, trust within. Internal service code trusts
  that the route already validated ownership; routes do the validation.
- Attach entity IDs to the error reporter on every financial route so an
  incident points at the offending row in one click.
- Confirm a new test is reachable by the runner (imported or
  glob-discovered) before calling it coverage.
- Write a one-sentence ADR header even on small architectural
  decisions: "we chose X because Y; the alternative was Z."
- Update the runbook in the same commit as the operational change that
  creates a new failure mode.

---

## 5. Multi-tenant invariants

These hold for every read and every write. A violation is a
priority-one bug regardless of customer impact. <!-- Delete this section
if your app is single-tenant. -->

- Every query that returns tenant-owned data filters by the tenant key.
  No exceptions.
- There is exactly one place that resolves the active tenant from the
  session. Routes that bypass it (cron, public, webhook) say so in a
  comment and carry their own auth gate.
- Service functions either take the tenant key and filter on it, or
  expose a `verifyXxxOwnership(id, tenantId)` helper the route is
  required to call before get/update/delete.
- A session pointing at a tenant the user is not a member of resolves to
  null. Never silently fall back to "first tenant".
- API keys carry scopes. Enforce the scope per HTTP method; admin-tier
  actions require an admin scope even when the user is an admin.
- A suspended/disabled tenant blocks every mutating action.
- If the database enforces row isolation, the app-level filter stays.
  Enforcement is the second layer, not the only one; and under
  enforcement an unwrapped query returns zero rows silently, so a
  wrapper gap is a live bug, not future debt.

---

## 6. Financial correctness invariants

Money correctness is the product wherever money is involved. <!-- Delete
if your app does not handle money. -->

- **Integer minor units.** Every monetary value at rest and in math is
  an integer count of the smallest unit (cents). Floating-point math on
  money is a defect.
- **Atomic multi-table writes.** All the rows for one financial event
  commit together or not at all. Use one transaction.
- **Idempotency.** Any write that can be retried (webhook, client retry,
  cron re-fire) is idempotent: a unique constraint, an `ON CONFLICT DO
  NOTHING`, or a `seen:<id>` key.
- **Split apportionment.** When you divide an amount across N parties,
  the parts sum back to the whole to the integer cent. Rounding each
  part independently drifts up to N-1 cents.
- **Separation of duties.** The actor who creates a payable cannot also
  approve or pay it. Bulk endpoints reject the whole batch if any row
  would self-approve.
- **AI spend cap.** Every model call routes through a budget assertion
  before issuance and a spend record after.
- **No silent money changes.** Any job that mutates money writes a
  corresponding audit-log row inside the same transaction. A money
  write inside a swallowing catch is a defect: it will not 500, it will
  quietly not write.
- **A guard is not immutability.** A refusal on one request path proves
  that one path refuses. Before writing "never", "always", "permanent"
  or "cannot" about a money column, grep every writer of it (cascades,
  resyncs, crons, admin tools) and scope the claim to what you read.

---

## 7. Sensitive data / PII policy

**Display can be intentional.** If your product genuinely requires
authorized users to see sensitive fields to do their job, that display
is not the threat. Decide this consciously per field and write it down.

**Protection is exfiltration-focused.** What I defend against:

1. **DB dump / backup leak.** Every sensitive field is encrypted at
   rest (AES-256-GCM or equivalent). New sensitive columns add a
   constraint enforcing the ciphertext shape.
2. **Rogue read / curious insider.** Every render of a sensitive field
   writes a row to an append-only access log. Bulk reads log one entry
   with a row count.
3. **Error / log leak.** The error reporter and logs redact a known
   list of sensitive keys plus free-text patterns. New sensitive fields
   get added to the scrub list in the same change that adds the column.
4. **Model leak.** Sensitive attributes are filtered through the
   canonical list before any prompt, schema dump, or tool result reaches
   an LLM.
5. **Injection in rendering paths.** User-rendered HTML goes through a
   sanitizer or a strict allowlist.

Decide explicitly what you do NOT do (e.g. "we do not mask the tax ID
in the authorized analyst UI because the job needs it"). Write that
down so a future session does not "helpfully" add masking that breaks a
workflow, or remove protection that mattered.

---

## 8. Security defaults

Starting points; deviate only with an ADR.

- Authentication via a vetted library, not hand-rolled. Disable OAuth
  account-linking unless you need it (it can bypass a second factor);
  revoke sessions on password reset; enforce a sane minimum password
  length.
- Authorization is a fine-grained permission check, not mere
  membership. `requirePermission(ctx, "thing.do")` is the contract.
- Security headers: a content security policy (per-request nonces beat
  `unsafe-inline`), HSTS, `X-Frame-Options: DENY`, a locked-down
  permissions policy.
- Webhooks verify signatures with a timing-safe compare and per-tenant
  token resolution. Never fall back to "first provider in the DB".
- Cron jobs gate on a shared secret AND a platform-injected header
  (double auth) so a leaked secret is still unusable from outside.
- Public token URLs use 256-bit entropy and store only the hash at rest.
  Plaintext lives only in the URL you send out.
- Rate limit user-facing endpoints with a shared store (e.g. Redis). An
  in-memory fallback is opt-in and logs a warning in production.
- Any user/tenant-configurable outbound URL goes through an SSRF check
  that DNS-resolves and blocks private, loopback, link-local, and cloud
  metadata ranges.
- Outbound HTTP uses a wrapper with a default timeout. A hung upstream
  blocks the worker and, under load, exhausts the connection pool.
- A CI job scans the lockfile for known vulnerabilities and fails on
  CRITICAL; a secret scanner runs on every push.

---

## 9. Deploy discipline

Source of truth: the repo's deploy doc (`WORKFLOW.md` if you keep
one). The rules I treat as inviolable:

- <!-- State your branching/deploy model and why it is safe. A good
  default is push-to-mainline behind a CI deploy gate. If you use PRs
  and a protected branch, say so. --> <Deploy model, one line.>
- Migrations run via the one sanctioned runner only. Never as part of
  the build. Never directly against prod with the raw ORM CLI.
- A new migration gets its journal entry in the same commit as the SQL,
  with a watermark newer than the last applied entry.
- A failed CI run blocks production. Push the fix, do not bypass.
- CI green is not "deployed". Confirm the deploy for the exact SHA
  reached its ready state.
- The platform rollback (promote the previous deploy) is the fast lever.
  Use it first, investigate afterwards.

---

## 10. Incident response (the first five minutes)

Source of truth: `RUNBOOK.md` if you keep one. The shape:

1. Verify the incident is real (health check + error reporter +
   DB/infra dashboard).
2. If the latest deploy correlates: roll back first. Investigate after.
3. If data corruption: restore to a fresh DB branch, verify, then swap.
   Never restore directly over production.
4. Communicate, even solo: post the timeline somewhere durable for the
   post-mortem.
5. Post-mortem within 24 hours. Action items go into the work queue with
   an owner and a date.

---

## 11. Architecture decisions (ADRs)

I write an ADR when a decision spans more than two files/services,
rejects a plausible alternative someone will later re-suggest, or
encodes a non-obvious tradeoff that will fade from memory.

I do not write an ADR for bug fixes, small refactors, or one-file
choices.

ADRs live in `<docs/adr/>` numbered sequentially. Status values:
Proposed, Accepted, Superseded by NNNN, Deprecated. Never delete; link
forward.

---

## 12. Code quality bar

The numbers that mean "production ready":

- The typechecker is clean. Always.
- The test suite passes 100%, and every committed test is reachable by
  the runner. Always.
- New non-trivial pure functions have a unit test. Cross-table writes
  have an integration test.
- Strict type checking is on. Escape hatches (`any` and friends) are a
  code smell; net delta per change is <= 0.
- No `console.log` (or your language's equivalent) in production code
  paths.
- No `TODO` / `FIXME` without a date and an owner. A TODO without a
  next step is a defect.
- No commented-out blocks. Version control remembers; delete it.

### 12a. Lines-of-code budget (the size rule)

**The bar: no new file crosses 400 LOC. Period.**

Exceptions:

- A file may grow above 400 LOC if it carries a
  `PRINCIPLES: max-lines-exception: <reason>` comment in its first 20
  lines (use the file's comment syntax). Reasons that pass:
  "single-purpose generated schema", "template that mirrors a print
  layout", "exhaustive enum/constant catalog." Reasons that fail:
  "harder to split than to grow", "we'll refactor later", "it's fine."
- An existing file already over 400 LOC may receive bug fixes and minor
  additions, but a feature that adds >50 LOC to it triggers a
  split-first commit. Splits ship in their own commit separate from the
  feature.

Track your worst offenders here with target sizes and a refactor
strategy, so each new feature landing in them is a known split
opportunity. This rule is enforceable via a `max-lines` lint rule or a
pre-commit hook that runs `wc -l` on staged source files.

Service/orchestration modules can carry a higher tolerance (e.g. 800
LOC) if you say so explicitly. Route handlers should be tighter (e.g.
150 LOC); business logic belongs in services, not handlers.

---

## 13. Refactor safety (the four-tier rule)

- **Tier 1 (zero risk):** lint rules, dead-code deletion, doc changes,
  type-only refactors. Ship freely.
- **Tier 2 (low risk):** mechanical splits with a re-export index,
  moving logic from a route to a service. Ship, verify with lint +
  tests.
- **Tier 3 (medium risk):** splitting an interactive god-file one piece
  at a time, hook/component extraction. Requires the corresponding
  end-to-end test to exist FIRST. Ship, watch the error reporter for 48
  hours, then continue.
- **Tier 4 (high risk):** changes to a signed/financial/auth flow, a
  storage migration, enabling row-level security. Requires e2e coverage
  of the touched flow, a dual-write or audit-mode rollout phase, and an
  ADR.

A refactor I cannot fit into one of these tiers is a refactor I have not
thought hard enough about.

---

## 14. Communication style

When I report progress to the user:

- Lead with the result, not the journey.
- Cite files and line numbers, not vague references.
- State what I did NOT do as explicitly as what I did.
- Surface risks the user might not see ("this changes behavior for X
  when Y").
- Distinguish claim types: what I read this session (checkable), what I
  inferred, what I recalled. Never present a recalled source as a read
  one.
- Use complete sentences. Do not say "Done" without context.
- One short summary at end of turn. No multi-paragraph wrap-ups unless
  asked.

---

## 15. Tools I reach for (the canonical list)

Before writing my own utility, I check whether one exists. <!-- Maintain
a table here mapping each common need (auth context, encryption at rest,
sensitive-read audit, atomic money write, rate limit, constant-time
compare, outbound fetch with timeout, SSRF-safe URL check, request body
validation, money formatting) to the canonical module in your repo. If I
find myself writing a near-duplicate of one of these, I stop and use the
canonical version. -->

| Need | Module |
|---|---|
| Auth context | `<lib/auth.getAuthContext>` |
| Encryption at rest | `<lib/encryption>` |
| Sensitive-read audit | `<services/sensitive-access-log>` |
| Atomic money write | `<services/…-cascade>` |
| Outbound fetch with timeout | `<lib/timed-fetch>` |
| SSRF-safe URL check | `<lib/url-validation>` |
| Rate limit + client IP | `<lib/rate-limit>` |
| Constant-time compare | `<lib/validators.safeEqual>` |
| Request body validation | `<lib/parse-body>` |
| Money formatting | `<lib/money.formatMinorUnits>` |

---

## 16. The top-tier bar (concrete examples)

What "best in class" looks like in practice, mapped to this codebase:

- **Idempotency everywhere.** Every webhook handler is idempotent on the
  upstream's primary key. New webhooks add a `seen:` key BEFORE side
  effects.
- **Defense in depth.** App-level tenant filters AND database-level
  isolation AND append-only audit triggers. A single missed check must
  not be sufficient to leak.
- **Observability.** Every important event has an error-reporter context
  block, an audit-log row, and a structured log line. Triage is "click
  the id, see the row in 30 seconds."
- **Money math.** Integer minor units, deterministic split ordering,
  sum-invariant tests.
- **Access control.** Separation of duties on sensitive actions,
  per-key scopes with method-awareness.
- **Compliance posture.** Append-only audit logs, encrypted sensitive
  data at rest, scrub-on-the-way-out for error reports, documented
  retention windows.
- **Specialist review before push.** A diff that touches money,
  tenancy, migrations, or an LLM call site gets a dedicated review pass
  (a reviewer subagent with its own checklist, or at minimum `/review`)
  before it ships, not after it breaks.

---

## 17. Reading order on a new session

When the session boots and I am about to make changes:

1. `MEMORY.md` index: what the user has saved.
2. `CLAUDE.md`: brand rules, deploy flow, what this repo does not have.
3. `WORKFLOW.md`: the deploy pipeline if I am shipping.
4. `RUNBOOK.md`: if production is involved or might be.
5. This file: the operating doctrine.
6. The most recent ADR relevant to the area I am about to touch.
7. The specific service/route I am about to change, end to end, before I
   write the diff.

If I make a change that contradicts steps 1-6, I stop and write the ADR
first.

---

## 18. What this file is not

- Not a justification for excessive ceremony. If the change is small,
  the diff is small.
- Not a substitute for thinking. Principles inform judgment; they do not
  replace it.
- Not immutable. When a principle no longer serves the product, I update
  it via ADR.

The bar is: would a new senior engineer joining in six months read this
file and immediately understand how to operate here? If not, this file
needs work.

---

## 19. Verification craft (how a review lies to itself)

Every item here is a way a green signal was produced without the thing
being true. They are listed because each one has cost a real team real
hours, more than once.

- **A detector that cannot fail proves nothing.** Before trusting a
  green, state what RED would have looked like and confirm this run
  could have produced it. Then run the control: remove the alternative
  explanation rather than re-running the same check.
- **A test no runner imports never runs.** It reads, in a file listing
  and in a diff, exactly like coverage. Runners that execute only what
  their entry point imports need a reachability guard whose allowlist
  ships empty and only shrinks. The sibling failure: a suite that skips
  silently and reports zero failures.
- **A pipe hides an exit code.** `check | tail` exits with `tail`'s
  status. Redirect to a file and echo `$?`, or read the tool's own
  status field. A CI watcher's `--exit-status` treats a CANCELLED run as
  neither pass nor fail; read the `conclusion`.
- **An empty result and a crashed tool look identical.** Before trusting
  a zero-hit scan, feed the detector an input that MUST match, and check
  the tool's exit code, not the pipe's.
- **Exclude the observer.** A grep that matched the marker you wrote
  while composing the test, an artifact that predates your run, a
  watcher that fired on a neighbour's mtime: none is evidence.
- **A guard is not immutability.** One path refusing proves one path
  refuses. Enumerate every writer before saying "never".
- **Widening a set misses its consumers.** Adding a member to an enum,
  union, permission set, or action list does not fail to compile at
  consumers that matched the old members by string literal or prefix.
  Grep the old member first; prefer a shared predicate or explicit map.
- **A count in a commit message is a claim.** "Declared three times, now
  once" is how many copies the author found. Grep the VALUE and its
  spellings (SQL literals included) before building on the number, and
  guard a centralization with a check that counts declarations, not a
  test of the helper.
- **A fix can be right while its reason is false.** The wrong reason is
  what propagates: a commit message becomes settled fact for every later
  session. Before extending an inherited finding, prove the failure mode
  is reachable (which input, which config), not just that the code
  matches the pattern. If the premise turns out false, revert the work
  built on it, including any guard that encodes it.
- **Absence claims are scoped to what was searched.** "Not in the repo"
  from a stale worktree is a claim about that worktree. Say which ref
  and which patterns.
- **Copy that lists a sample reads as exhaustive.** State the rule, not
  three of four cases; the noun must match the filter.
- **Unloaded looks absent.** Code that reads a not-yet-loaded value and
  treats it as empty is the most common UI defect shape. Gate on a load
  signal, never on emptiness.
- **A green suite is not a look.** For UI, fetch the artifact (the
  screenshot, the rendered page) and look at it. Passing assertions
  describe what was asserted, nothing more.
