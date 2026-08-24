# QA Sweep

Canonical brief for sweeping a deployed target for bugs before (or
after) users see a change. Consumed by the `/qa-sweep` command and
usable verbatim as a brief for any other coding agent. The
deterministic layer also runs nightly via the workflow in
`qa/qa-sweep.yml.template`.

Fill the placeholders during kickoff: your app URL, your QA sandbox
tenant, your QA member login env var names.

## Identity and boundaries (non-negotiable)

- Sign in as the QA sandbox MEMBER login (low privilege), never an
  owner or admin session: a sweeping agent clicks everything, and
  member role caps the blast radius (no admin-only mutations).
- Create records freely inside the QA sandbox tenant. NEVER delete
  files/documents if your blob store is shared with prod (deleting a
  sandbox file can delete the real blob). Never touch any tenant other
  than the QA sandbox.
- Do not trigger outbound sends (email/SMS) unless the operator
  explicitly asked for a send test. Sandbox sends are REAL sends that
  happen to sink into a mailbox you control.
- Read-only on every page outside the QA sandbox scope.

## Pre-flight

1. Confirm no deploy is in flight: latest CI run complete and any
   rolling release finished (newest deploy older than ~15 minutes).
   Sweeping mid-rollout mixes old and new builds and produces
   false-positive hydration errors (React #418). Wait it out.
2. Pick the target: prod (default) or the staging alias from
   `stage:up`. Note Vercel SSO on preview deployments blocks the
   deterministic layer unless a protection bypass secret is set.
3. Say what a FAILING sweep looks like before starting (which spec
   fails, which output line). A killed or partial run yields no verdict.

## Layer 1: deterministic sweep (always run first)

```bash
cd <your-web-app-dir>
BASE_URL=<target> \
TEST_USER_EMAIL=$QA_AGENT_EMAIL \
TEST_USER_PASSWORD=$QA_AGENT_PASSWORD \
TEST_TENANT_ID=$QA_TENANT_ID \
pnpm exec playwright test pages-smoke --project=setup --project=chromium --reporter=line
```

Renders every static route (filesystem-discovered) and fails on 5xx,
client-side crashes, error boundaries, and 500ing same-origin fetches.

Known blind spot: a member login gets 403 on admin-only APIs before
they can 500, so admin-only server bugs pass a member sweep. Cover
admin paths in CI (admin test user) or run a second sweep with admin
credentials.

## Layer 2: exploratory pass (agent-driven, on demand)

Drive a real browser through the flows a deterministic spec cannot
judge. Work as a user would; judge what you see. Adapt this circuit to
your app and weight it by what changed recently:

1. Login -> switch into the QA sandbox tenant.
2. Open a core record, edit a field, save, reload, verify it stuck.
   Add a note. Check the activity log recorded both.
3. Create a core record end to end, then find it via search.
4. Open a record with attachments: files render and preview.
5. Move a record through one workflow stage and back; verify it stuck.
6. Money/report pages: numbers consistent across pages for the same
   seeded records.
7. Watch everywhere for: console errors, failure toasts, spinners that
   never resolve, empty states where data should be, saves that
   succeed without changing anything (the unloaded-looks-absent class),
   layout breakage, horizontal scroll at phone width.

Judge severity honestly: a dead button on a revenue path is critical,
a misaligned badge is cosmetic.

## Reporting (findings file contract)

Write the report to `qa-findings.md` at the repo root (gitignore it;
overwritten each sweep). This exact shape, because the /ship fix loop
parses it:

```markdown
# QA Findings
target: <url>
swept_at: <ISO timestamp>
layers: 1 | 1+2
verdict: CLEAN | FINDINGS

## F1: <one-line title>
severity: critical | high | medium | cosmetic
route: /path
did: <the action taken>
expected: <what should have happened>
observed: <what happened instead>
evidence: <console/network/error excerpt, verbatim>
reproduces: yes (confirmed on second attempt)
prod_impact: <would this misbehave in production, and how do you know>
```

Rules: findings that survive a second reproduction attempt only;
nothing for rolling-release hydration noise (see pre-flight); severity
judged honestly; no fix gets written until `prod_impact` holds up
against production behavior (a staging-only artifact is not a finding).
A CLEAN verdict still lists what was covered. When a finding describes
a flow worth protecting forever, propose the scripted spec that would
gate it (agents scout, deterministic tests gate).
