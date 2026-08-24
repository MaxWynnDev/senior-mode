# QA sandbox seed checklist

The QA sandbox is a persistent, synthetic-data tenant living in your
PRODUCTION database, so real integrations (email, OAuth connections,
crons, file storage) work against it, and any prod-DB branch you create
for staging inherits it automatically. The seed code is necessarily
app-specific; this checklist is the contract it must satisfy.

## Non-negotiables

1. **Synthetic data only. Never copy real customer data into it.** The
   whole point is that test emails, agent clicks, and screenshots can
   touch everything with zero customer risk. Use obviously-fake
   identifiers (e.g. SSN-shaped values from ranges never issued,
   `.example` domains).
2. **Safe by isolation, not by refusing prod.** The seed only ever
   creates a NEW tenant and writes inside it, and teardown fully
   reverses it. Idempotent re-runs; `--reset` / `--teardown` flags.
3. **Create through your services, not raw SQL**, so invariants
   (encryption at rest, money-chain consistency, audit logs) hold and
   the sandbox stays representative.

## What to create

- The tenant itself, flagged in settings (e.g. `isQaSandbox: true`) so
  it is programmatically identifiable. Do NOT flag it with whatever
  switch your e2e suite uses to no-op outbound email; the QA sandbox
  exists to send for real through a test mailbox.
- The human owner as the tenant's top role.
- **A member-role (low-privilege) sweep login** for automated agents.
  Strong random password, printed once, stored in your env file and CI
  secrets. Member role on purpose: an agent that clicks everything
  must not be able to trigger admin-only mutations.
- **Fake counterparties whose contact emails sink into a mailbox you
  control.** Plus-addressing works well: `you+qa-vendor-a@yourco.com`.
  Two mailbox gotcha: if your inbound-ingest pipeline skips messages
  whose From equals the connected mailbox, the sink mailbox MUST be a
  different account than the tenant's connected sending account, or
  the reply loop can never be tested.
- Records across your pipeline's stages, weighted toward the states
  your riskiest flows start from, with realistic attachments (your
  size-limit and bounce paths need real files).
- A couple of records with the FULL downstream chain (whatever
  funded/fulfilled means in your domain) so money/report pages have
  data.

## Manual steps to document (cannot be scripted)

- Any OAuth consent (e.g. connecting a TEST email account as the
  tenant's sender). Use a throwaway account, never your real sending
  account.

## Aftercare

- Your prod crons will process the sandbox's rows. That is usually
  desirable (more realism); confirm none of them send anything beyond
  your sink mailbox.
- Shared infrastructure caveats to verify for your stack: file/blob
  storage shared with prod (deleting a sandbox file may delete a real
  blob), shared rate-limit buckets, metrics pages that aggregate
  across tenants.
