---
name: feedback-prompt-engineering-rubric
description: When designing or touching Claude API prompts, apply the 10-part rubric in PROMPTING.md
metadata:
  type: feedback
---

For any new Claude API integration, or any change to an existing one,
apply the 10-part rubric and meta-rules in `PROMPTING.md` at the repo
root. Run the checklist before merging.

**Why:** an audit against this rubric once caught a multi-week-stale
hardcoded date in a cached system prompt (a real accuracy bug). The
rubric prevents that class of bug.

**How to apply:**
- New AI feature: read PROMPTING.md first, then build. Tick every box.
- Touching an existing AI prompt: patch the specific gap; don't refactor
  the whole prompt. Verify `system` stays byte-identical for cache hits.
- Highest-priority rules: system/user split, never hardcode dates in
  cached blocks, post-parse validation, spend-budget gate before send,
  XML-delimit any user-supplied prompt fragment.

See also: [[feedback-prompt-standard]].
