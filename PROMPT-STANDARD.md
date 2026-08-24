# Prompting Claude Code

The standard for how to brief Claude Code in this repo. Distinct from
`PROMPTING.md`, which is for API system prompts inside the app.

## When this applies

The standard kicks in for non-trivial prompts to Claude Code:

- Build, edit, or refactor any file
- Multi-step work
- Anything touching money paths, auth, migrations, or live data
- Ambiguous "fix this" / "improve that"

It does NOT apply to:

- Codebase Q&A ("how does X work?", "where is X defined?")
- Quick lookups
- Casual conversation
- One-line shell commands

## The 5-element standard

A non-trivial prompt should have:

| # | Element | Required answer |
|---|---|---|
| 1 | GOAL | What outcome? "Fix X." "Build Y." "Audit Z." |
| 2 | CONSTRAINT | What NOT to do. "Don't refactor." "No new files." |
| 3 | EVIDENCE | File paths, line numbers, error messages, screenshots. Not "the thing we talked about." |
| 4 | OUTPUT SHAPE | "Plan first." "Diff only." "Go fix it." |
| 5 | STOP CONDITION | When done? "When tests pass." "When UI matches mock." |

## Examples

### Below standard (Claude will call this out)

> "fix the checkout page"

Missing: which bug (GOAL), evidence (EVIDENCE), output shape (OUTPUT).

> "make the dashboard better"

Missing: definition of "better" (GOAL), constraint (CONSTRAINT), what
success looks like (STOP).

### Meets standard

> "Fix the order summary showing blank totals after save. The header
> shows the right grand total, every line item below is blank. POST
> `/api/orders` returns 200. Don't introduce new files. Find root
> cause, propose fix as a plan, wait for approval before editing. Stop
> after I approve the plan."

GOAL + EVIDENCE + CONSTRAINT + OUTPUT + STOP. All present.

## The 4-tier calibration contract

This is the exact line to honor. It is calibration, not nagging.

**Tier 1: pass through (no enforcement).**
Codebase Q&A, quick lookups, casual conversation, one-line shell
commands ("commit this", "run the tests"), bounded short prompts where
intent is obvious.

**Tier 2: 5 of 5 elements present.** Just do the work.

**Tier 3: 4 of 5 elements present.** Proceed BUT flag the inference in
one line: "Inferring OUTPUT=plan-first based on context; revise if
wrong."

**Tier 4: 2+ elements missing, OR money/auth-path work with ANY
element missing.** STOP. Do not start work. Name the missing elements
specifically, make a best-guess inference from context, wait for the
user's revision.

Higher-stakes paths (money, auth, migrations, anything with real blast
radius) get the higher bar because mistakes there are expensive.

## The 3 common bad-prompt patterns and the standard response

**Pattern A, "make it better":** vague GOAL, no EVIDENCE, no OUTPUT.
Response: "Below standard: GOAL too vague (what's wrong with it?), no
EVIDENCE (which page? which component?), no OUTPUT shape, no STOP. Best
guess: <inference>. Confirm or revise."

**Pattern B, "the thing from yesterday":** no EVIDENCE.
Response: "Below standard: no EVIDENCE. Yesterday's session isn't
loaded; I can search git log + memory but you'll get a better result by
pasting the file path + symptom. Which bug?"

**Pattern C, "build a whole new feature":** missing OUTPUT and STOP for
multi-file work.
Response: "Below standard for a multi-file build: missing OUTPUT (plan
first or write?) and STOP. Suggest: paste the spec, tell me which
route, pick plan-first vs build-first. I'll wait."

## How Claude enforces this

When you submit a non-trivial prompt missing required elements, Claude
will identify which elements are missing, suggest concrete additions
based on what it can infer, and wait for your revision before doing
any work. If you guess right 90% of the time, asking for clarification
on the 10% saves more time than guessing wrong.

## Delegate, don't pair

Treat Claude like an engineer you delegated to, not one you are
pair-programming with. The 5 elements ARE the crisp brief: goal,
constraints, acceptance criteria. Then let it run; it performs best
with fewer interruptions and a real feedback loop (see Verification
loops). Come back for the result or a genuine question, not to watch.
Course-correct by rewinding, not by arguing (see Context hygiene).

For a genuinely ambiguous multi-file build, start in plan mode
(`/plan <description>`, or Shift+Tab twice): Claude researches and
proposes before it edits, and you approve the plan once instead of
correcting the implementation piecemeal.

## Where an instruction should live

A recurring confusion, worth settling once:

| It is a... | Put it in | Loaded |
|---|---|---|
| Fact every session needs (build command, brand, deploy model) | `CLAUDE.md` | every turn (keep under ~200 lines) |
| Convention for one layer or path | `.senior-mode/rules/<area>.md` with `paths:` frontmatter | only when matching files are touched |
| Multi-step procedure or checklist | a skill: `.agents/skills/<name>/SKILL.md` (or `.senior-mode/commands/<name>.md`) | only when invoked or judged relevant |
| Reviewer with its own checklist | `.senior-mode/reviewers/<name>.md` | when delegated to |
| Rule that must hold regardless of what the agent decides | a hook (`.senior-mode/hooks/`, wired per agent) | enforced by the harness |
| How the USER works (tone, approval style, risk appetite) | auto memory (`feedback_*`) | index every session, file on demand |

`/learn` picks the destination for you in that order of preference.
Prose in CLAUDE.md is context, not enforcement; a hook is enforcement.

## Context hygiene (long sessions)

The context window is a working set, not a scrapbook. Habits that keep
long-running work sharp:

- **Rewind, don't correct.** When an approach failed, do not type
  "that didn't work, try X": that keeps the failed attempt in context,
  where it keeps costing attention. `/rewind` to before the attempt and
  re-prompt with what you learned. Ask for "summarize what you learned
  from here" first when the failure taught something worth carrying.
- **`/clear` for a new task, `/compact` for a related one.** `/compact`
  (optionally with a hint about what to keep) is a lossy summary that
  keeps momentum; `/clear` plus a written handoff is exact. Project-root
  CLAUDE.md survives compaction; conversation-only instructions do not,
  so anything that must persist goes into CLAUDE.md or a rule.
- **`/branch` to try a direction, `/fork` to keep working.** Branch the
  conversation for an experiment you may abandon; fork it into a
  background session for something independent.
- **`/context` when in doubt.** It shows what is loaded and what is
  eating the window.
- **Rules beat repetition.** If you keep re-explaining the same
  convention across sessions, stop: `#` it into memory or run `/learn`
  so it becomes a rule that loads itself.

## Quick wins (keyboard + voice)

- **Dictation.** On Windows, `Win+H` opens Voice Typing. Speak prompts;
  the 5-element standard makes spoken prompts coherent.
- **`#` to remember.** When Claude does something you want every time,
  hit `#` and type the rule. It goes into memory.
- **`!` for bash output.** Prefix shell commands you want Claude to see
  the output of. Lands directly in context.
- **`@` to mention files.** Drag-drop also works in the terminal.
- **Drag PDFs / images.** Drop mocks, screenshots, docs into the
  terminal. Claude Code is multimodal.
- **Shift+Tab** cycles permission modes (auto-accept for low-stakes
  iteration, plan mode for design).
- **`/effort`** raises or lowers reasoning depth for the session;
  **`/fast`** toggles fast mode for mechanical turns.
- **Escape** to interrupt safely.

## Verification loops

The single biggest performance gain in Claude Code is giving it a
check it can run itself against (the "oracle"), and letting it iterate
until the check passes. A loop turns "plausible code" into "verified
code" without you in the inner cycle.

Instead of:

> "Build the order summary."

Try:

> "Build the order summary. Then run the dev server, navigate to the
> page, screenshot it, compare to the mock at `<path>`, iterate on
> styling until it matches. Then run tests. Fix anything that breaks.
> Stop when both match the mock and tests pass."

Costs more tokens, lands much closer to right on the first pass.

### Anatomy

Every loop is the 5-element standard with teeth:

```
GOAL            what to make true
ORACLE          the check command (or remote job) that decides, automatically
ACTION          the smallest fix consistent with the failure
STOP CONDITION  oracle green, or the iteration cap
BUDGET          max iterations (default 4) before stop-and-report
```

The oracle IS your STOP CONDITION made executable. A loop without a
trustworthy oracle is just expensive wandering.

### The oracle hierarchy (best to worst)

1. A failing unit test: precise, fast, deterministic.
2. Typecheck / build: deterministic, repo-wide, slower.
3. e2e suite: real but slow, some timing sensitivity.
4. Screenshot vs mock: visual, needs judgment, great for UI.
5. A `verify-*` invariant script: as good as the invariant it asserts.
6. Self-review: not a loop. Use `/review` or `/pre-push` instead.

In the remote-heavy verification model (WORKFLOW.md), each of these is
a CI job for the pushed SHA rather than a local command; the hierarchy
and the integrity rules are unchanged.

### Oracle integrity (NON-NEGOTIABLE)

The classic loop failure is optimizing the oracle instead of the goal:

- Never delete, skip, or comment out a failing test to get green.
- Never loosen an assertion, widen a type, or relax a threshold so
  the check passes.
- Never swap the agreed check for a weaker one mid-loop. Narrowing to
  one test file for iteration speed is fine; the full check runs once
  at the end.
- If the test itself is wrong, STOP the loop and say so with evidence.
  Changing the oracle is a human decision, not a loop iteration.

### Say what RED looks like

Before trusting a green signal, state what its failing output would
have been and confirm this run could have produced it. Detectors that
cannot fail: a test file no runner imports (reads as coverage, never
runs), a suite that reports `0 failed` because `0 ran`, a watcher whose
exit code was replaced by the `| tail` after it, a grep that matched
the marker you wrote yourself, a scan whose tool crashed and printed
nothing. A green from any of these carries no information. Section 19
of ENGINEERING-PRINCIPLES.md is the full list.

### The strongest form: tests first

For new behavior, invert the order: write the failing test from the
spec FIRST, confirm it fails for the right reason, then loop the
implementation until green. The test encodes the spec before the
implementation can negotiate with it.

### When to loop

- A cheap, deterministic oracle exists or is one test away.
- The failure is mechanical: type errors, broken tests after a
  refactor, a dep bump, lint debt, UI-vs-mock styling.
- The fix space is local; each iteration is independently checkable.

### When NOT to loop

- No trustworthy oracle (design taste, copy tone, architecture
  choices). One-shot + human review wins.
- The oracle is expensive or flaky per iteration (full CI, timing-
  sensitive e2e). Run it once at the end instead of inside the loop.
- The failure needs a decision a human owns: money semantics, schema
  shape, anything in your migration ritual or multi-agent territory. On
  those paths the bar is adversarial review (`/pre-push`, the
  specialist agents), not just a green bar.
- Same failure signature twice with no progress: stop and rethink the
  diagnosis instead of iterating harder.

Flake rule: identical failure twice = real. A different failure each
run with no code change = suspect flake; rerun once before chasing it.

### The loop ladder (which loop, at which altitude)

| Loop | Altitude | Use when |
|---|---|---|
| `/iterate <check>` | inner, one turn | a deterministic check should gate this change |
| `/verify` (bundled) | inner, one turn | confirm a change against the running app, not just tests |
| Screenshot loop | inner, one turn | UI work against a mock |
| Tests-first loop | inner, one turn | new behavior with a writable spec |
| `/go` | per change | the finish line: verify end to end (app-verifier), simplify, review, commit |
| `/pre-push` | per push | non-trivial diff; fans out the review agents |
| `/ship` | per deploy | the verified ship loop through CI and the deploy |
| `full-audit` workflow | repo-wide | scheduled deep sweep (multi-agent opt-in) |
| `/batch` (bundled) | repo-wide, parallel | a wide mechanical change across many files, one subagent per slice in its own worktree |
| Ralph loop (plugin) | multi-turn, unattended | wide mechanical backlog where every item has its own oracle. Never on money paths or migrations. |
| `/loop` (bundled) | across time | watching external state (CI, deploys, queue drains); with no interval it self-paces |
| `/schedule` (routines) | on a calendar | a recurring cloud job: nightly sweep, weekly digest |

`/iterate` packages the inner loop with the integrity rules and the
iteration cap. See `.senior-mode/commands/iterate.md`.

## Parallel work

Two altitudes, both intended working styles.

**Parallel agents (one session).** For independent subtasks, ask for
parallel agents:

> "Spawn 3 agents in parallel: one writes the migration, one writes the
> migration runner, one writes the test fixtures. Each in its own
> worktree. Merge back when all three finish."

Faster than serial, and each agent has its own context window so the
main session stays uncluttered. Delegate mechanical fan-out to a
cheaper model via the `model` parameter; keep judgment on the strong
one. A `fork` subagent inherits your full conversation when the task
needs everything you already know; `isolation: worktree` gives an
agent its own tree when it will edit files.

**Parallel sessions (one per task).** Running 2-4 Claude Code sessions
at once, one per independent task, is how you get real throughput.
Number the terminal tabs, turn on terminal notifications so you know
which session needs input, and give each session its own working tree.
The kit's session hooks make this safe automatically: later sessions in
a shared checkout are steered to `/worktree` and the tangle guard
blocks their commits until they isolate. Details in CLAUDE.md
"Parallel sessions".

Two more ready-made parallel surfaces ship with this kit:

- `/pre-push` fans the review subagents in `.senior-mode/reviewers/` out
  against your current diff and aggregates one report.
- The `full-audit` workflow (`.claude/workflows/full-audit.mjs`) runs a
  repo-wide multi-agent audit with adversarial verification. Reserve it
  for when you genuinely want a full sweep; it spawns many agents.

## Slash commands available in this repo

See `.senior-mode/commands/*.md` for the full definitions, and the list at
the bottom of `CLAUDE.md`.
