---
description: Turn a correction or hard-won insight from this session into a durable rule (hook, path rule, skill, CLAUDE.md, or memory) so no future session repeats the mistake.
argument-hint: [the lesson | blank = infer from the latest correction]
---

GOAL: compound this session's learning. A correction typed into chat
fixes one run; a rule written into the repo fixes every future run.
Capture ONE lesson as a durable rule in the right place.

EVIDENCE: the lesson is `$ARGUMENTS` when given. When blank, identify
the most recent correction, surprise, or repeated mistake in this
conversation (the user said "no, do X", a hook blocked you, a check
failed for a preventable reason, you discovered a non-obvious project
fact the hard way).

## Step 1: generalize it

State the rule in one or two sentences, project-general, with the WHY.
"Use the date helpers" is weak; "bare YYYY-MM-DD through new Date()
renders yesterday west of UTC, so all date display goes through
src/lib/date.ts" survives contact with a future session. Drop
session-specific trivia (ticket numbers, one-off filenames). Verify the
premise against the current code first: a rule that encodes a false
rationale is worse than no rule, because it teaches the wrong thing to
everyone who reads it.

## Step 2: pick the ONE right destination

In order of preference:

1. **A hook or check** when the rule is mechanically enforceable (a
   grep-able pattern, a threshold). Enforcement beats prose: extend the
   `pre-commit-audit.sh` / `ultracode-advisor.sh` vocabularies or the
   relevant gate, add a harness case, then re-run
   `bash .senior-mode/hooks/test-checklist.sh`. Prove the detector by
   feeding it the exact input that shipped the mistake.
2. **`.senior-mode/rules/<area>.md`** when it only applies to one layer or
   path. Give the rule file `paths:` frontmatter so it loads only when
   matching files are touched.
3. **A skill (`.agents/skills/<name>/SKILL.md`)** when the lesson is a
   multi-step PROCEDURE rather than a fact (a checklist, a recipe).
   Skills load on demand; CLAUDE.md content costs context every turn.
4. **`CLAUDE.md`** when it is a project-wide FACT every session needs.
   Respect the line budget (~200 lines): if CLAUDE.md is getting long,
   move detail to a rules file and leave one line here.
5. **Memory (`feedback_*` / `project_*` / `reference_*`)** when it is
   about how the USER works (tone, approval style, risk appetite), or
   project state the repo does not record. Follow the memory frontmatter
   conventions and add the one-line pointer to `MEMORY.md`.

## Step 3: dedupe, then write

Search the destination (and its siblings) for an existing rule covering
this. If one exists, sharpen it in place rather than appending a
near-duplicate; two half-rules are worse than one whole one. Then make
the edit.

CONSTRAINT: one rule per invocation. Never delete unrelated content.
Never write secrets, customer data, or one-off session detail into a
rule. Repo-file edits are committed with the session's other work, not
pushed on their own.

OUTPUT SHAPE: print the final rule text, where it went, and why that
destination. If you extended a hook, show the harness output.

STOP CONDITION: the rule is written (or an existing rule sharpened) and
confirmed in one short message. Then stop.
