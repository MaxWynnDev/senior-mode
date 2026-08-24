# How to brief Claude Code

Most "Claude is being dumb" moments are briefing problems. This is the
standard that fixes them. Install at `~/.claude/PROMPTING-CLAUDE-CODE.md`
(the global CLAUDE.md points here) and read it once.

## When this applies

Non-trivial prompts: building, editing, or refactoring files; multi-step
work; anything touching money, auth, migrations, or live data; vague
"fix this" / "improve that".

It does NOT apply to codebase Q&A, quick lookups, casual conversation,
or one-line shell commands.

## The 5-element standard

| # | Element | Required answer |
|---|---|---|
| 1 | GOAL | What outcome? "Fix X." "Build Y." "Audit Z." |
| 2 | CONSTRAINT | What NOT to do. "Don't refactor." "No new files." |
| 3 | EVIDENCE | File paths, line numbers, error messages, screenshots. Not "the thing we talked about." |
| 4 | OUTPUT SHAPE | "Plan first." "Diff only." "Go fix it." |
| 5 | STOP CONDITION | When done? "When tests pass." "When UI matches mock." |

### Below standard

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

## The 4-tier calibration contract (how Claude enforces it)

- **Tier 1, pass through:** Q&A, lookups, chat, one-liners, bounded
  short prompts where intent is obvious.
- **Tier 2, 5 of 5 present:** just do the work.
- **Tier 3, 4 of 5 present:** proceed, but flag the inference in one
  line ("Inferring OUTPUT=plan-first; revise if wrong").
- **Tier 4, 2+ missing, or money/auth work with ANY element missing:**
  stop, name the missing elements, make a best guess, wait.

Calibration, not nagging. If Claude guesses right 90% of the time,
asking on the other 10% is cheaper than guessing wrong.

## Delegate, don't pair

Treat Claude like an engineer you delegated to, not one you are
pair-programming with. The 5 elements ARE the brief. Then let it run;
it performs best with fewer interruptions and a real feedback loop.
Come back for the result or a genuine question, not to watch.

For a genuinely ambiguous multi-file build, start in plan mode
(Shift+Tab twice): Claude researches and proposes before it edits, and
you approve once instead of correcting the implementation piecemeal.

## Verification loops (the single biggest win)

Give Claude a check it can run itself against and let it iterate until
the check passes. Instead of:

> "Build the order summary."

Try:

> "Build the order summary. Then run the dev server, open the page,
> screenshot it, compare to the mock at `<path>`, iterate on styling
> until it matches. Then run tests. Fix anything that breaks. Stop when
> both match the mock and tests pass."

Costs more tokens, lands much closer to right on the first pass.

**Oracle hierarchy (best to worst):** a failing unit test; typecheck /
build; e2e suite; screenshot vs mock; an invariant script. Self-review
is not a loop.

**Oracle integrity (non-negotiable):** never delete, skip, or weaken a
failing test to get green; never swap the agreed check for a weaker one
mid-loop; if the test itself is wrong, stop and say so. Cap loops at ~4
iterations. Same failure twice with no progress: stop and rethink.

**Tests first** for new behavior: write the failing test from the spec,
confirm it fails for the right reason, then loop the implementation.

**Say what RED looks like.** Before trusting a green, state what its
failing output would have been and confirm this run could have produced
it. A test no runner imports, a suite reporting "0 failed" because 0
ran, a watcher whose exit code got replaced by the `| tail` after it:
green from any of these carries no information.

## Where an instruction should live

| It is a... | Put it in |
|---|---|
| Fact every session needs (build command, stack, deploy model) | the repo's `CLAUDE.md` (keep under ~200 lines) |
| Convention for one layer or path | `.claude/rules/<area>.md` with `paths:` frontmatter |
| Multi-step procedure | `.claude/commands/<name>.md` (a slash command) |
| How YOU work (tone, approval style, risk appetite) | memory: type `#` then the rule |
| Rule that must hold no matter what Claude decides | a hook in `.claude/settings.json` |

Prose in CLAUDE.md is context; a hook is enforcement.

## Context hygiene (long sessions)

- **Rewind, don't correct.** When an approach failed, do not type "that
  didn't work, try X" (the failed attempt stays in context, eating
  attention). `/rewind` to before it and re-prompt with what you learned.
- **`/clear` for a new task, `/compact` for a related one.**
- **`/context`** shows what is loaded and what is eating the window.
- **Rules beat repetition.** Re-explaining the same thing across
  sessions? Make it a memory or a CLAUDE.md line.

## Quick wins

- `#` then a sentence: saves a memory.
- `!` then a shell command: output lands in context.
- `@` to mention files; drag-drop files, images, and PDFs into the
  terminal.
- Shift+Tab cycles permission modes (auto-accept for low-stakes
  iteration, plan mode for design).
- `/effort` raises or lowers reasoning depth; Escape interrupts safely.
- Windows: `Win+H` dictates. The 5 elements make spoken prompts coherent.
