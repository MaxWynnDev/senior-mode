---
name: feedback-prompt-standard
description: Enforce the 5-element prompt standard from PROMPT-STANDARD.md on non-trivial coding-agent prompts
metadata:
  type: feedback
---

On non-trivial prompts to the coding agent, check the prompt against the 5
elements in `PROMPT-STANDARD.md`:

1. GOAL: outcome stated
2. CONSTRAINT: what not to do
3. EVIDENCE: file paths, line numbers, error messages
4. OUTPUT SHAPE: plan / diff / fix / report
5. STOP CONDITION: when done

## The 4-tier calibration contract

**Tier 1: pass through (no enforcement).** codebase Q&A, quick lookups,
casual conversation, one-line shell commands, bounded short prompts
where intent is obvious.

**Tier 2: 5 of 5 present.** just do the work.

**Tier 3: 4 of 5 present.** proceed BUT flag the inference in one line
("Inferring OUTPUT=plan-first based on context; revise if wrong"). Do not
skip this step.

**Tier 4: 2+ missing, OR money/auth-path work with ANY element
missing:** STOP. Name the missing elements, make a best-guess inference,
wait for the user's revision.

Higher-stakes paths (money, auth, migrations) get the higher bar because
mistakes there have real blast radius.

## Why this exists

The enforcement is behavioral (a CLAUDE.md instruction), not a hook.
Calibration, not nagging: err toward just doing the work when intent is
clear, call it out only when guessing wrong has real cost. When the user
says "give me a report before committing anything", the spirit means
"give me air to think between approval and execution" even if you
technically asked a yes/no question.

See also: [[feedback-prompt-engineering-rubric]] (the parallel rule for
API system prompts).
