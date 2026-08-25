---
description: Scaffold a new LLM-powered service with the project rubric baked in
argument-hint: <feature-name>
---

Build a new LLM-powered service named "$ARGUMENTS" in your services
directory.

Read `PROMPTING.md` at the repo root first, then follow the pattern of
your most thorough existing AI call site (PROMPTING.md "Reference call
sites" names it once one exists). The skeleton:

- A PURE prompt module (`<name>-prompt.ts` or equivalent) that owns the
  system prompt constant, the user-prompt builder, and the post-parse
  validator, with no database or framework imports, so the eval harness
  can import it.
- A side-effect shell (`<name>.ts`) that: resolves the client/config
  helper, asserts the spend budget before send, calls the model with the
  cached system block and a forced tool call (structured output) where
  the shape allows, retries on 408 / 429 / 500 / 502 / 503 / 504 / 529,
  records spend after the response, validates the output, and persists
  status if applicable.
- Model ID read from the ONE config module, pinned to an exact version.
- At least one golden eval case in the project's eval harness.

Before writing any code, present a plan covering:

1. What the feature does (one sentence)
2. Input shape
3. Output shape (the tool schema or JSON schema)
4. What goes in `system` (cacheable) vs `user` (per-call, including
   today's date if the task is date-sensitive)
5. Validation rules, and which fields coerce vs hard-fail
6. The confidence gate (what "cannot tell" looks like in the output)
7. The eval case(s) that will lock the behavior

Wait for my approval before writing the file. Do not skip the plan step.
Confirm: should I proceed with the plan?
