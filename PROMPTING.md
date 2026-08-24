# Prompting Claude (API system prompts)

Playbook for designing Claude API system prompts in this repo. Distinct
from `PROMPT-STANDARD.md`, which is for briefing Claude Code in a
session. Source: Anthropic's "Prompting 101" by the Applied AI team,
updated for current API capabilities.

## The 10-part prompt anatomy

A well-engineered prompt has up to ten ordered components. Each does a
specific job. Not every prompt needs all ten.

1. Task description and role. "You are a <role> at <product>." Sets
   stakes and authority.
2. Static content. Things that never change between calls (schema,
   business rules, taxonomies). Put in `system`. Cacheable.
3. Dynamic content. The actual input to process this call. Put in
   `user`. Not cached.
4. Detailed step-by-step instructions. Order matters. Read facts before
   interpretations.
5. Few-shot examples. For edge cases where intuition fails.
6. Conversation history. If user-facing.
7. Immediate task reminder. Restate what to do right now after context.
8. Important guidelines. Guardrails. "Only answer if confident." "Don't
   invent." "Refer to source."
9. Output format. A forced tool call with a schema, XML tags, or strict
   JSON. Spec it explicitly.
10. Prefilled assistant response. Start the reply with `{` or
    `<final_verdict>` to force structure. Prefill and extended thinking
    are mutually exclusive: use one or the other, not both.

## Meta-rules

These compound on top of the rubric and apply to every Claude
integration.

- **System vs user split.** Static schema, taxonomy, behavioral rules
  go in `system` with `cache_control: ephemeral`. Per-call data (CSV
  samples, PDFs, the actual question) goes in `user`. Keep `system`
  byte-identical across calls so the cache hits. For blocks that change
  rarely, use the extended cache TTL so the cache survives longer than
  the default few-minute window.
- **Don't hardcode dates in cached prompts.** Today's date drifts.
  Inject `today` via the `user` block, not the cached `system` block. A
  stale hardcoded date in a cached system prompt is a real, silent
  accuracy bug.
- **Validate output post-parse.** Treat Claude's output as untrusted
  input. Run a shape checker before downstream code consumes it, even
  when the API already validated a tool-call schema. Calibrate coerce
  vs hard-fail per field: cosmetic drift may coerce; a money metric
  never silently defaults.
- **Budget gate every call.** Assert you are under a spend cap before
  sending, and record spend after. An uncapped loop drains a budget
  fast at frontier-model prices.
- **Confidence gating.** Tell Claude to set `skip: true` or
  `"NOT EXTRACTABLE"` when it doesn't know. This is the
  highest-leverage hallucination guard.
- **Citations for source-grounded extraction.** When the answer comes
  from a supplied document, enable citations so each extracted figure
  points back to its source span. Stronger than asking the model to
  quote the source in prose. (Citation blocks fragment a strict-JSON
  text response; weigh the tradeoff on strict-JSON sites.)
- **Use XML tags for delimited sections.** Claude was fine-tuned on
  `<tags>`. Markdown headers work but tags are stricter, especially when
  interpolating user-supplied content.
- **Retries plus backoff.** Anthropic returns 408, 429, 500, 502, 503,
  504, 529. Retry with exponential backoff.
- **Extended thinking is first-class, not just a debugger.** Turn it on
  for any step that benefits from reasoning before answering (judgment
  calls, multi-constraint mapping); with tool use, interleaved thinking
  lets the model reason between tool calls. On current models prefer
  adaptive thinking or the effort setting over a hand-tuned token
  budget: the model scales reasoning depth to the problem instead of
  padding to a fixed budget. It is still the best prompt debugger too:
  read the scratch pad and patch the prompt at the exact spot where the
  model's reasoning diverges from yours. It cannot be combined with
  assistant prefill.
- **Give the model a test, not a fact, for grounding.** When output
  must match a closed vocabulary (proper nouns, slugs, enum values), do
  not just list the vocabulary; tell the model every emitted value must
  exist in the supplied list and have the validator reject the rest.

## Picking a model

- Keep model IDs in ONE config module so an upgrade is a one-line
  change, and pin exact versioned IDs (not bare aliases) in production
  paths so behavior does not shift under you. The spend/pricing table
  must know every ID in use or spend recording breaks silently.
- Default product features to the current frontier tier (the Claude 5
  family: Fable 5 where available, otherwise Opus 5); downgrade a call
  site to the balanced tier (Sonnet 5) only after it passes your evals
  on that task.
- Use the fast tier (Haiku 4.5 as of this writing) for mechanical,
  high-volume work: classification, routing, judge/verifier passes,
  memory extraction, convention sweeps. The conventions-sweeper agent in
  this kit runs on it for exactly that reason.
- Batch non-interactive bulk work through the Batches API when latency
  does not matter; it is materially cheaper than streaming the same
  calls.
- For long-running agentic loops, use the SDK's tool-runner helper or a
  managed-agent runtime rather than a hand-rolled loop, and turn on
  context compaction so a long session does not overflow. The
  server-side memory tool is the right primitive for state an agent
  must carry across sessions.
- Large documents go through the Files API once, then are referenced
  by id, rather than re-uploaded per call.

## Output formatting choices

| Pattern | When to use |
|---|---|
| Tool-use structured output (forced tool call, schema validated at the API) | The most reliable way to get a typed object back. Prefer this when a forced tool call fits the shape. |
| Strict JSON schema in prompt plus post-parse validation | Pipeline output where a tool call does not fit. |
| XML wrapper around final verdict | When Claude should reason out loud and you extract the verdict from a tagged block. |
| Plain text streaming | Chat. |

For new pipeline features, prefer a forced tool call with a schema
(structured output) over prompt-and-parse; fall back to JSON-in-prompt
plus a validator when a tool call does not fit the shape. For new agent
features (long-running tool use), prefer XML around the final answer so
the reasoning is auditable. Validate post-parse either way: output is
untrusted.

## Checklist for new Claude features

- [ ] Role and task stated in first sentence of system prompt
- [ ] All static content in `system` with `cache_control: ephemeral`
- [ ] Per-call data lives in `user`
- [ ] Today's date and other moving values are NOT in cached blocks
- [ ] Output format specified explicitly
- [ ] Structured output via a forced tool call where the shape allows;
      prompt-and-parse only as fallback
- [ ] Output validated post-parse (coerce vs hard-fail decided per field)
- [ ] Confidence gating wired ("set skip:true if you can't tell")
- [ ] Spend cap asserted before sending
- [ ] Retry block handles 408 / 429 / 500 / 502 / 503 / 504 / 529
- [ ] Spend recorded after the response
- [ ] Any user-supplied prompt fragment is delimited with XML tags
- [ ] Exact versioned model ID from the one config module
- [ ] Prompt, builders, and validator in a pure module; at least one
      golden eval case

The `prompt-auditor` subagent in `.senior-mode/reviewers/` runs this checklist
against any call site; `/audit-prompt <file>` invokes the same rubric
inline.

## Evals are the oracle

Prompt quality is not reviewable by eye, and `/iterate` needs a check
to point at. Once you have one or two AI features, build a small eval
harness:

- **Split each AI service into a pure module and a side-effect shell.**
  The pure module owns the system prompt, the prompt builders, and the
  post-parse validator, with no DB or framework imports. The service
  imports it; so does the harness. Evals then exercise the EXACT
  production prompt without touching your database. A purity test locks
  this.
- **Golden fixtures with known ground truth, synthetic only.** Generate
  fixtures deterministically (seeded randomness) so the truth is exact
  and runs are reproducible. Never put real customer data in a fixture.
  Assert what the fixture actually HOLDS, not a bar below it.
- **Programmatic graders first.** Field-level assertions with explicit
  tolerances on the validated output. The single strongest structural
  grader: every reference the model emits (attribute slug, enum value,
  file id) must exist in the schema you fed it, so hallucinations fail
  loudly. Add an LLM judge only for genuinely fuzzy criteria.
- **Real API, on demand, fingerprint-gated in CI.** The point is testing
  the real model + prompt pair, so runs cost real money: keep suites
  small, print the cost, and in CI fingerprint the prompt + eval inputs
  so an unchanged fingerprint with a cached success proof skips the paid
  run while a changed one blocks the deploy until it passes.
- **Never loosen a tolerance to get green.** A failed eval is a real
  regression or a conscious recalibration that belongs in the commit
  message. Same oracle-integrity rules as PROMPT-STANDARD.md. An oracle
  can lie both ways: a grader that cannot fail proves nothing.
- **A new AI feature ships with its eval cases.** Scaffolding is not
  done until at least one golden case exists.

## Progressive disclosure for domain knowledge

Domain reference material for an agent does NOT belong in the system
prompt. Keep it as reviewable markdown, compile it into a bundle, and
let the agent load a document on demand through a tool. The always-on
cost is one index line per document inside the cached block; a document
body is billed only on the turns that need it. Prose is also something
a domain expert can read and correct, which a template literal is not.
Keep one source of truth: if a document restates a rule that also lives
in a prompt module, generate one from the other rather than forking.

## Establish reference call sites

Once you have one or two well-built Claude services in this repo, list
them here as the patterns to copy. A new AI feature should be a
near-clone of your most thorough existing call site, not a fresh design.

<!-- SETUP: replace this section with pointers to your real call sites
once they exist, e.g. "`src/services/foo-analyzer.ts`: the most thorough
prompt in the repo, good model to copy." -->

## Building AI on Vercel

If you deploy on Vercel and use the AI SDK, prefer the AI Gateway with
plain `"provider/model"` strings rather than provider-specific packages,
unless you specifically need direct provider wiring. The gateway gives
you observability, fallbacks, and zero-retention routing. Streaming
works on the default Node.js runtime; you do not need the edge runtime
for it.
