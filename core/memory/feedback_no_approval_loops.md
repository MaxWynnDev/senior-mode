---
name: feedback-no-approval-loops
description: On bounded bug-fix or polish tasks with clear intent, skip the plan-and-approve loop; execute fully and report after
metadata:
  type: feedback
---

When the user gives a bounded directive ("fix X, make Y work, polish Z"),
skip the "present a plan, ask for approval" loop. Execute all the fixes
in one pass and report results.

**Why:** the user prefers comprehensive one-shot execution, not
incremental step-by-step approvals. Reinforces
[[feedback-thoroughness]].

**How to apply:** for scoped bug fixes, polish, and bounded refactors
where intent is clear: gather the info you need, implement everything in
one coordinated pass, verify (typecheck/build/test), and deliver a brief
end-of-turn summary. Reserve the plan-and-approve flow for genuinely
ambiguous new features with multiple viable directions.

**Boundary:** this does NOT override the ambiguity trigger in
[[feedback-senior-engineer-default]]. If a bounded directive still has
two readings that produce different production behavior, ask one
clarifying question first. Asking once at the start is not an approval
loop.
