---
name: feedback-evidence-before-code
description: The audit comes BEFORE the action, visibly, in the same response; a post-hoc confession is not an audit
metadata:
  type: feedback
---

Confirm the diagnosis with evidence before the first edit, and show that
confirmation to the user in the same response, not after the commit.
The AFTER-hook is a safety net; if it finds real gaps, the BEFORE step
failed.

**Why:** the recurring failure shape is three consecutive turns of
(push, audit, confess). Prose memory did not fix it; a visible template
at the decision moment did.

**How to apply:** before ANY edit, commit, or deploy on a non-trivial
change, output this block first:

```
[BEFORE-AUDIT]
- Diagnosis: <hypothesis + the evidence it rests on>
- Missing evidence: <what would confirm it; if "none needed", justify>
- 100% version: <named>
- 80% gap: <what I would skip and why>
- Senior would reject if: <specific failure mode>
- Action: <confirm-first | ship | ask>
```

Empty or "n/a" lines are fine when genuinely n/a; lying is the gap.
Strict-superset, zero-risk fixes do not skip the block: they fill
"Missing evidence: none load-bearing, change is a strict superset" and
proceed.

Two corollaries:

- Verify the writer before building the reader. One COUNT query, one
  log line, one curl that proves the data exists beats an afternoon of
  UI built on an assumption.
- A fix can be right while its stated reason is false, and the wrong
  reason is what propagates: commit messages get read as settled fact
  by every later session. Before extending an inherited finding, prove
  the failure mode is reachable in this codebase, not just that the
  code matches the pattern.

Related: [[feedback-senior-engineer-default]],
[[feedback-never-cite-an-unread-source]].
