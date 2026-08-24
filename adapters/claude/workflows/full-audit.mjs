export const meta = {
  name: 'full-audit',
  description: 'A-to-Z security + quality audit: parallel dimension finders, adversarial verification of every material finding, synthesis into one ranked, scored report. Read-only.',
  phases: [
    { title: 'Find', detail: 'dimension finders sweep the whole repo (read-only)' },
    { title: 'Verify', detail: 'adversarial verification of every CRITICAL/HIGH/MEDIUM finding' },
    { title: 'Synthesize', detail: 'dedupe, rank, score, write the report' },
  ],
}

// This is a UNIVERSAL template. It ships with generic dimensions and a
// generic rubric drawn from ENGINEERING-PRINCIPLES.md. Tune DIMENSIONS,
// RUBRIC, PREAMBLE, and PRIOR to your project, then run (only when you
// have opted into multi-agent work):
//   Workflow({ name: 'full-audit', args: { date: '2026-01-01', baseline: 7.0 } })
// date/baseline are optional; scripts cannot read the clock, so pass a
// date via args if you want one in the report.
//
// REVIEWER: the subagent type for finders and verifiers. `undefined`
// uses the default workflow subagent, which is always available. Set it
// to a registered custom or plugin agent (e.g. 'feature-dev:code-reviewer')
// only if that agent exists in your session; an unknown type errors.
const REVIEWER = undefined
// Effort for the adversarial verifiers and the synthesis. Finders inherit
// the session effort; verification is where a wrong call costs the most.
const VERIFY_EFFORT = 'high'

const DATE = (args && args.date) || 'undated'
const BASELINE = (args && typeof args.baseline === 'number') ? args.baseline : null

const RUBRIC = `RUBRIC (from ENGINEERING-PRINCIPLES.md; the bar is best-in-class for this domain):
NEVER: store money as float (integer minor units always); store sensitive data in plaintext at rest; do a multi-table financial write outside a transaction; trust client X-Forwarded-For for client IP unless a trusted-proxy flag is set; use raw fetch for outbound (use a wrapper with a timeout); accept untrusted JSON without schema validation at the route boundary; use string equality on secrets (constant-time compare); run DDL outside a numbered migration; write from a GET handler.
ALWAYS: every tenant-owned query filters by the tenant key; one place resolves the active tenant from the session; bypass routes (cron/public/webhook) declare it and carry their own gate; encrypt sensitive data at rest and log every sensitive render; constant-time compare secrets; validate at the boundary, trust within; attach entity ids to the error reporter on financial routes.
MONEY: integer minor units; atomic multi-table writes in a transaction; idempotency on anything retryable; splits sum back to the whole to the cent; separation of duties (the creator of a payable cannot approve/pay it); AI spend cap before each model call; an audit-log row in the same transaction as any money mutation; no silent non-writes (a money write inside a swallowing catch is a defect).
TENANT: a session pointing at a non-member tenant resolves to null (never fall back to first tenant); API keys carry method-aware scopes; admin tier needs the admin scope; a suspended tenant blocks every mutation.
SECURITY: vetted auth library, account-linking disabled unless needed, sessions revoked on password reset, sane min password; CSP nonces, HSTS, X-Frame-Options DENY; webhooks verify signatures timing-safe with per-tenant token; cron gates on a shared secret plus a platform header; public tokens are 256-bit and stored only as a hash; rate limit via a shared store; tenant-configurable URLs go through an SSRF check (blocks RFC1918/loopback/link-local/metadata); child processes get an explicit env allowlist, never the parent's whole environment.
QUALITY: typechecker clean; tests pass AND are reachable by the runner (a test file no runner imports is not coverage); no new file over 400 LOC without a "PRINCIPLES: max-lines-exception" comment; no console.log in prod paths; no TODO without date and owner; no commented-out blocks.
DATES: never build a Date from a stored bare YYYY-MM-DD string then format with toLocaleDateString(), and never derive today via toISOString().slice(0,10); both bite the calendar-date timezone bug class.
UI: never treat "not loaded yet" as "empty"; gate on an explicit load signal.`

// Prior audit state, if any. Finders VERIFY each item against the current
// code rather than assuming it; a recorded rationale can be wrong.
const PRIOR = ``

const PREAMBLE = `You are a senior security and quality auditor reviewing this codebase.
Discover the stack yourself (read package.json / the manifest, the directory layout, CLAUDE.md, and ENGINEERING-PRINCIPLES.md) before judging.

HOW TO WORK
- This is a STATIC, READ-ONLY audit. Do NOT modify any file. Do NOT run any command that writes, mutates git, installs, or connects to a database or network. If the local DATABASE_URL might point at production, never connect to it. Read-only inspection only.
- Discover the real code with Glob and Grep, then READ the actual files in full before judging. Do not guess from filenames or from this brief.
- Every finding MUST cite a concrete file path and line or range and quote the offending code as evidence. No evidence, no finding.
- Prove the failure MODE is reachable, not just that the code matches a pattern: name the input or config that makes it misbehave. An odd-looking shape is a lead, not a conclusion.
- Precision over volume. A false positive wastes a downstream verification slot. An empty findings array is a good answer for a clean dimension.
- Severity honesty: CRITICAL = directly exploitable cross-tenant access, money corruption/theft, sensitive-data exfiltration, auth bypass, or data loss. HIGH = serious but conditional. MEDIUM = a real weakness or missing defense-in-depth. LOW/INFO = hygiene. Set confidence (high/medium/low) per finding.
- Report at most 20 findings, highest conviction first. Do not pad.

${RUBRIC}
${PRIOR ? '\n' + PRIOR : ''}`

const FINDINGS_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    dimension: { type: 'string' },
    summary: { type: 'string', description: 'one or two sentences: what was reviewed and the overall posture' },
    findings: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        properties: {
          title: { type: 'string' },
          severity: { type: 'string', enum: ['CRITICAL','HIGH','MEDIUM','LOW','INFO'] },
          file: { type: 'string' },
          line: { type: 'string' },
          description: { type: 'string' },
          evidence: { type: 'string' },
          impact: { type: 'string' },
          recommendation: { type: 'string' },
          confidence: { type: 'string', enum: ['high','medium','low'] },
        },
        required: ['title','severity','file','description','impact','recommendation','confidence'],
      },
    },
  },
  required: ['dimension','summary','findings'],
}

const VERDICT_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    verdict: { type: 'string', enum: ['confirmed','refuted','uncertain'] },
    reasoning: { type: 'string' },
    adjustedSeverity: { type: 'string', enum: ['CRITICAL','HIGH','MEDIUM','LOW','INFO','unchanged'] },
  },
  required: ['verdict','reasoning'],
}

const SYNTHESIS_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    overallScore: { type: 'number' },
    posture: { type: 'string' },
    executiveSummary: { type: 'string' },
    counts: {
      type: 'object', additionalProperties: false,
      properties: {
        critical: { type: 'number' }, high: { type: 'number' }, medium: { type: 'number' }, low: { type: 'number' },
        verified: { type: 'number' }, needsReview: { type: 'number' }, refuted: { type: 'number' },
      },
      required: ['critical','high','medium','low'],
    },
    topRisks: {
      type: 'array',
      items: { type: 'object', additionalProperties: false, properties: { title: { type: 'string' }, severity: { type: 'string' }, file: { type: 'string' }, dimension: { type: 'string' } }, required: ['title','severity','file'] },
    },
    reportMarkdown: { type: 'string', description: 'the full audit report body in markdown' },
  },
  required: ['overallScore','posture','executiveSummary','counts','topRisks','reportMarkdown'],
}

const DIMENSIONS = [
  { key: 'tenant-isolation', title: 'Multi-tenant isolation & access control (IDOR)', scope:
`Audit multi-tenant isolation and per-record access control across the whole API + service layer. For each route and service: tenant-owned reads/writes filter by the tenant key; the tenant id comes from the session/context and NEVER from the request body or query; routes with an [id] param call an ownership check before get/update/delete (IDOR risk if they fetch by id alone); per-record ACLs where member visibility is restricted; API-key scope + method-aware enforcement; suspended-tenant mutation block; fine-grained permission checks (not mere membership) on admin-only actions. If row-level security exists, list tenant-scoped writes NOT wrapped in the tenant helper that silently return zero rows under enforcement, and any privileged bypass helper used inside an ordinary per-tenant handler. Highest value: any route that can return another tenant's data.` },

  { key: 'authn-session', title: 'Authentication, sessions, API keys, route-auth coverage', scope:
`Audit authentication, sessions, API keys, and route-auth coverage. Verify the auth library config (account-linking disabled, sessions revoked on password reset, sane min password); API keys hashed at rest and compared constant-time, carrying scopes; EVERY route either resolves auth via the shared resolver or is explicitly in the public-route allowlist with its own gate (cron double-auth; webhook signature; public token hash). Flag any route that queries data before auth or trusts a middleware-injected identity, and any GET handler that writes. Check CSRF/origin on cookie-auth surfaces. Cross-check the public-route allowlist against the actual route tree for drift.` },

  { key: 'money-paths', title: 'Financial correctness & integrity', scope:
`Audit financial correctness end to end (skip if the app handles no money). Verify against RUBRIC: money is integer minor units (flag float arithmetic on money); multi-table financial writes wrapped in a transaction; idempotency present on anything retryable; splits sum to the whole to the cent; separation of duties enforced (creator cannot approve/pay); AI spend gated; money mutations write an audit-log row in the same transaction; bounds validation; suspended-tenant block; no money write whose failure is swallowed. Before accepting any "never changes" claim about a money column, enumerate every writer of it.` },

  { key: 'sensitive-data', title: 'Sensitive data / PII exfiltration', scope:
`Audit sensitive-data handling for EXFILTRATION risk (intentional in-app display to authorized users is not the threat; confirm what is intentional from CLAUDE.md / ENGINEERING-PRINCIPLES). Verify: every sensitive column encrypted at rest with a ciphertext-shape constraint; no code path writes them in plaintext; every render of a sensitive field is logged to an append-only access log; the error reporter and logs scrub all sensitive keys plus free-text patterns; sensitive fields are stripped before any LLM call; child processes do not inherit the whole environment. Flag plaintext-at-rest, leakage to logs/error-reporter/the LLM, cross-tenant exposure, and unauthorized export.` },

  { key: 'injection-output', title: 'Injection & output safety (SQLi, XSS, prompt injection)', scope:
`Audit injection and output safety. (a) SQL: every dynamic value is a parameterized placeholder, never concatenated user input; raw SQL templates that interpolate a language array or object where a scalar is expected are unchecked casts. (b) XSS: every raw-HTML sink is sanitized (DOMPurify) or fully static/trusted; markdown/rich-text rendering is sanitized. (c) Prompt injection: user-supplied fragments are delimited, sensitive data filtered, model output validated before use/persist. (d) CSV formula injection on exports (guard the leading =,+,-,@).` },

  { key: 'api-hardening', title: 'API surface hardening (rate limit, validation, error shape)', scope:
`Audit API hardening across all routes. Verify: user-facing and AI routes rate limit with sane limits; AI routes also assert a spend budget; request bodies validated with a schema at the boundary; error responses use consistent shapes and never leak raw DB errors; tenant id never read from the body; HTTP methods constrained; client IP only via the safe helper. Quantify coverage (how many routes lack rate limiting or validation).` },

  { key: 'secrets-crypto', title: 'Secrets, cryptography & configuration', scope:
`Audit secrets, crypto, and config. Verify: symmetric encryption used correctly (unique random IV per encryption, auth tag verified on decrypt, key length validated); ALL secret/token/signature comparisons are constant-time (grep for === / !== / .includes on secrets); env validation rejects known-default/example secrets and refuses a prod boot without required keys; public link tokens stored only as a hash at rest; security headers present. Run a read-only secret scan with Grep for high-signal patterns (sk-, AKIA, BEGIN PRIVATE KEY, hardcoded Bearer tokens) and report any real secret committed to source.` },

  { key: 'supply-chain', title: 'Dependencies & supply chain', scope:
`Audit dependencies and supply-chain posture from the manifests and lockfile (read-only; do not run an installer or scanner). Verify: overrides/pins target patched versions and name what advisory each addresses; security-sensitive dependencies sit on supported lines; installed-but-unused packages that add attack surface are flagged; a CI job scans the lockfile for known vulnerabilities and fails on CRITICAL. Report concrete version risks, not generic advice; say what you could not prove.` },

  { key: 'outbound-ssrf-files', title: 'Outbound HTTP, SSRF, webhooks & file handling', scope:
`Audit outbound HTTP, SSRF, webhook authenticity, and file handling. Verify: every outbound request uses the timeout wrapper, not raw fetch; every user/tenant-configurable destination URL passes an SSRF check that DNS-resolves and blocks RFC1918/loopback/link-local/cloud-metadata; webhooks verify signatures timing-safe with per-tenant token resolution (no fall back to the first provider in the DB); file uploads validate magic bytes + MIME + sanitized filename + size cap; stored files are access-scoped.` },

  { key: 'correctness-bugs', title: 'Correctness & logic bugs', scope:
`Hunt high-confidence correctness and logic bugs, prioritizing anything that corrupts money or data integrity. Look for: unhandled null/undefined, swallowed catch blocks, missing await before a commit or response, race conditions and non-idempotent retries, state-machine errors, off-by-one and boundary errors in math, UI that treats "not loaded yet" as "empty", consumers that match an enum member by string literal or prefix and miss newly added members, and timezone/calendar-date bugs (building a Date from a bare YYYY-MM-DD then formatting, or deriving today via toISOString().slice(0,10)). Report only bugs you can prove from the code with a concrete failure scenario.` },

  { key: 'architecture-loc', title: 'Architecture, LOC budget & dead code', agentType: 'Explore', scope:
`Audit architecture, the LOC budget, and dead code (quality, not security). Use read-only Bash wc -l (PowerShell Measure-Object undercounts blank lines). Per ENGINEERING-PRINCIPLES section 12a: list every source file exceeding 400 LOC WITHOUT a "PRINCIPLES: max-lines-exception" comment. Report the worst offenders and their sizes. Also count: type-escape-hatch usage, console.log in non-script prod paths, TODO/FIXME without date+owner, commented-out code, and obvious dead/unused exports. Give counts and the worst offenders; this informs refactor sequencing, not a security gate.` },

  { key: 'tests-migrations', title: 'Test coverage, migrations & schema drift', scope:
`Audit test coverage, migration discipline, and schema-drift risk. Verify: critical money paths have tests AND those tests are reachable by the runner (list test files no runner entry point or glob picks up: they read as coverage and never execute); contract tests lock any canonical schema definition to the self-healing helpers; migrations are additive (no destructive DROP shipped alongside code that still references the column); every migration SQL file has a matching journal entry with an advancing watermark (no orphan, no journal entry without SQL, no stale timestamp); the schema-drift pattern is followed for any new canonical attribute (idempotent backfill + self-healing service + contract test). Also check observability: do financial routes set error-reporter context and capture silent rollbacks?` },

  { key: 'frontend-quality', title: 'Accessibility, brand & date-handling compliance', scope:
`Audit frontend accessibility, brand/copy compliance, date handling, and phone-width layout. Accessibility: every interactive element has an aria-label or visible text; focus-visible not disabled; 4.5:1 contrast; keyboard nav works. Brand copy in user-facing strings: flag wrong brand-name casing, em/en dashes or hyphens-as-punctuation, emoji in email subjects, copy that enumerates a sample of cases where it should state the rule. Date handling: flag the inline antipattern (building a Date from a stored string then formatting, or deriving today via toISOString().slice(0,10)); must use the date helpers. Layout: fixed widths, nowrap, bare grids without explicit columns, and clipping ancestors that would hide an overflow at phone width. Forms: schema-validated, submit disabled while in-flight, inline field errors. Report concrete file:line instances grouped by category.` },
]

function finderPrompt(d) {
  return `${PREAMBLE}

YOUR DIMENSION: ${d.title}

${d.scope}

Return your result via the structured schema: dimension (this title), summary (one or two sentences on coverage and posture), and findings (array). Empty findings is acceptable if the dimension is genuinely clean.`
}

function verifyPrompt(f, lens, dTitle) {
  const lensText = lens === 'mitigation'
    ? 'Specifically hunt for a MITIGATING CONTROL elsewhere in the codebase that already neutralizes this: a canonical helper, a wrapper, an upstream validation, an encrypt-at-rest path, a tenant guard, a DB constraint. Adopt the stance that the finding is probably already handled and try to prove it. If a control fully neutralizes the issue, return refuted.'
    : 'Specifically attempt to REFUTE that this is real and exploitable. Construct the actual code path. If the cited file/line does not say what the finding claims, or the input is not attacker-controlled, or the value is static/trusted, or the config that would make it misbehave is unreachable, return refuted. Default to refuted unless you can confirm the exploit or defect from the real code.'
  return `You are an adversarial verifier for a security audit (dimension: ${dTitle}). A finder reported the finding below. Re-open the cited file(s) yourself with Read and Grep and judge it ONLY from the real current code. ${lensText}

This is READ-ONLY: do not modify anything, do not touch the database or network.

FINDING:
- title: ${f.title}
- severity: ${f.severity}
- file: ${f.file}
- line: ${f.line || '(unspecified)'}
- description: ${f.description}
- claimed evidence: ${f.evidence || '(none provided)'}
- impact: ${f.impact}

Return verdict=confirmed only if the defect is real in the current code, refuted if it is not real or is fully mitigated, uncertain only if the code is genuinely ambiguous. Give concrete reasoning citing what you actually read (file:line). Suggest an adjustedSeverity if the finder mis-rated it.`
}

function compact(f) {
  return { dimension: f.dimension, title: f.title, severity: f.severity, file: f.file, line: f.line || '', confidence: f.confidence, status: f.status, description: f.description, impact: f.impact, recommendation: f.recommendation, verifierNotes: f.verifierNotes || '' }
}

function synthesisPrompt(dims, findings) {
  const summaries = dims.map(d => `- ${d.title}: ${d.summary}`).join('\n')
  const baselineLine = BASELINE !== null
    ? `SCORE the codebase 0 to 10 relative to the prior baseline of ${BASELINE}. Justify the delta with specifics.`
    : `SCORE the codebase 0 to 10. Justify the score with specifics.`
  return `You are the lead auditor writing the final audit report${DATE !== 'undated' ? ` dated ${DATE}` : ''}. Dimension finders swept the whole repo and every material finding was adversarially verified. Below are the per-dimension coverage summaries and the full verified finding set as JSON. Synthesize a single authoritative report.

DIMENSION COVERAGE:
${summaries}

VERIFIED FINDINGS (JSON; status is one of verified / needs-review / refuted / unverified-low / unverified-capped / unverified-error):
${JSON.stringify(findings)}

YOUR JOB:
1. DEDUPE findings that describe the same root issue across dimensions; merge into one, keep the highest severity, list all affected files.
2. RANK by real risk (severity times confidence times exploitability). Treat status=refuted as NOT a current vulnerability (move to an appendix). Treat status=needs-review as an open question. Treat verified as confirmed.
3. ${baselineLine} State the posture in one line.
4. PRIORITIZED REMEDIATION PLAN: an ordered list. Each item is what, where (file:line), the minimal fix, effort (S/M/L), and whether it is a single commit or needs a migration/multi-step refactor. Separate "ship this week" from "sequenced".
5. Write reportMarkdown as the full report: title and date, executive summary, score with rationale, a counts table, findings grouped by severity each with file:line plus impact plus fix, the remediation plan, and a refuted/needs-review appendix. Cite file:line everywhere.

Also populate the structured fields: overallScore, posture, executiveSummary, counts, topRisks (the 8 to 10 highest-priority verified items).`
}

// ---- run ----
log(`Full A-to-Z audit: ${DIMENSIONS.length} dimension finders, adversarial verification, synthesis. Read-only.`)
phase('Find')

const MATERIAL = new Set(['CRITICAL','HIGH','MEDIUM'])
const MED_CAP = 8

const dimResults = await pipeline(
  DIMENSIONS,
  (d) => agent(finderPrompt(d), { label: `find:${d.key}`, phase: 'Find', schema: FINDINGS_SCHEMA, agentType: d.agentType || REVIEWER }),
  async (res, d) => {
    const base = { key: d.key, title: d.title, summary: (res && res.summary) || '', findings: [] }
    if (!res || !Array.isArray(res.findings) || res.findings.length === 0) return base

    const material = res.findings.filter(f => MATERIAL.has(f.severity))
    const lowInfo = res.findings.filter(f => !MATERIAL.has(f.severity))
    const high = material.filter(f => f.severity === 'CRITICAL' || f.severity === 'HIGH')
    const allMedium = material.filter(f => f.severity === 'MEDIUM')
    const medium = allMedium.slice(0, MED_CAP)
    const medOverflow = allMedium.slice(MED_CAP)
    if (medOverflow.length > 0) log(`${d.key}: ${medOverflow.length} MEDIUM finding(s) carried unverified past the per-dimension cap of ${MED_CAP}`)
    const toVerify = high.concat(medium)

    const verified = await parallel(toVerify.map((f) => async () => {
      const isHigh = f.severity === 'CRITICAL' || f.severity === 'HIGH'
      const lenses = isHigh ? ['exploitability', 'mitigation'] : ['exploitability']
      const votes = (await parallel(lenses.map((lens) => () =>
        agent(verifyPrompt(f, lens, d.title), { label: `verify:${d.key}:${lens}`, phase: 'Verify', schema: VERDICT_SCHEMA, agentType: REVIEWER, effort: VERIFY_EFFORT })
      ))).filter(Boolean)
      const confirms = votes.filter(v => v.verdict === 'confirmed').length
      const refutes = votes.filter(v => v.verdict === 'refuted').length
      let status
      if (votes.length === 0) status = 'unverified-error'
      else if (refutes > confirms) status = 'refuted'
      else if (confirms === 0) status = 'needs-review'
      else status = 'verified'
      return { ...f, dimension: d.title, status, confirms, refutes, verifierNotes: votes.map(v => `[${v.verdict}] ${v.reasoning}`).join('  ||  ') }
    }))

    const carried = lowInfo.map(f => ({ ...f, dimension: d.title, status: 'unverified-low', confirms: 0, refutes: 0, verifierNotes: '' }))
    const overflowCarried = medOverflow.map(f => ({ ...f, dimension: d.title, status: 'unverified-capped', confirms: 0, refutes: 0, verifierNotes: '' }))

    return { key: d.key, title: d.title, summary: base.summary, findings: verified.filter(Boolean).concat(carried).concat(overflowCarried) }
  }
)

const dims = dimResults.filter(Boolean)
const allFindings = dims.flatMap(d => d.findings || [])
const compactFindings = allFindings.map(compact)
log(`Find + verify complete: ${dims.length} dimensions, ${allFindings.length} findings (${allFindings.filter(f => f.status === 'verified').length} verified, ${allFindings.filter(f => f.status === 'refuted').length} refuted). Synthesizing.`)

phase('Synthesize')
const synth = await agent(synthesisPrompt(dims, compactFindings), { label: 'synthesis', phase: 'Synthesize', schema: SYNTHESIS_SCHEMA, effort: VERIFY_EFFORT })

return {
  overallScore: synth.overallScore,
  posture: synth.posture,
  executiveSummary: synth.executiveSummary,
  counts: synth.counts,
  topRisks: synth.topRisks,
  reportMarkdown: synth.reportMarkdown,
  dimCount: dims.length,
  rawFindingCount: allFindings.length,
  verifiedCount: allFindings.filter(f => f.status === 'verified').length,
  refutedCount: allFindings.filter(f => f.status === 'refuted').length,
  needsReviewCount: allFindings.filter(f => f.status === 'needs-review').length,
}
