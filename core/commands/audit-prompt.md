---
description: Audit a Claude API call site against the rubric in PROMPTING.md
argument-hint: <path/to/file>
---

Read `PROMPTING.md` at the repo root, then audit the file at $ARGUMENTS
against every item in the new-feature checklist. For each item, report
PASS / MISS / N/A with a one-line reason.

Specifically check:

1. Role + task in first sentence of system prompt
2. Static content in `system` with `cache_control: ephemeral`
3. Per-call data in `user` (not in cached system)
4. No hardcoded dates or other moving values in cached blocks
5. Output format specified explicitly (forced tool call with a schema
   preferred; JSON schema or XML tags as fallback)
6. Output validated post-parse (defensive shape checker; money metrics
   never silently default)
7. Confidence gating ("set skip:true if unsure", or similar)
8. Spend-budget assertion before sending
9. Retry block handles 408 / 429 / 500 / 502 / 503 / 504 / 529
10. Spend recorded after response
11. User-supplied prompt fragments are XML-delimited (not concatenated)
12. Prefill XOR extended thinking (never both); adaptive thinking or an
    effort setting preferred over a hand-tuned token budget
13. Exact versioned model ID from one config module; pricing table
    knows the model
14. Prompt, builders, and validator in a pure module with eval cases

Report findings as a markdown table. Do NOT make changes. End with a
one-line overall verdict (READY / NEEDS WORK / CRITICAL). The
`prompt-auditor` subagent runs the same rubric with full-file reading;
use it from `/pre-push` for diffs, this command for a single file.
