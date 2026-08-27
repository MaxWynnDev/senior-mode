# Contributing

Two contributions are worth more than any other, so they come first.

## 1. Tell me an adapter is wrong

I ran Claude Code and Codex CLI end to end. The other seven adapters follow
their agent's documented hook format and pass the harness, but I have not
sat inside those agents. If you run Cursor, Gemini CLI, Copilot, OpenCode,
Factory Droid, Devin CLI, or Augment, the first prompt after install tells
you whether the check arrived.

Open an issue with the "Adapter report" template either way. Working is as
useful to know as broken. If it is broken, paste the payload your agent
actually sent (most of them log hook stdin somewhere) and I will fix the
shim; the payload is the whole fix.

## 2. Write a stack profile

A profile is a folder under `stacks/<name>/`. Copy the closest existing one
and rewrite it:

| File | What it must do |
|---|---|
| `detect.txt` | score your stack 20 or more, and its neighbours under 10 |
| `profile.json` | the picker card, plus commands that are real and current |
| `README.md` | assumptions, platform notes, what to adapt for sibling frameworks |
| `WORKFLOW.md` | the deploy pipeline and the migration runner's properties |
| `rules/*.md` | path-scoped rules with the real helper names for that stack |

Two hard rules. Every command in `profile.json` must be one you have run,
not one you remember; a wrong migrate command is worse than no profile.
And `detect.txt` has to be tested against a neighbour, not just your own
repo: run `bash stacks/detect.sh <a repo on the next stack over>` and check
you did not fire.

## Everything else

### Run the harness

```bash
bash core/hooks/test-checklist.sh
```

63 cases against scratch git repos (65 where bun is installed, which runs
the OpenCode plugin cases): every deny and allow path, the worktree
case, the stop-hook loop backstop, both shims in both directions, the
detector's verdicts, and a real install. It must print `ALL CASES [ok]`
before and after your change. CI runs it on Linux, macOS, and Windows.

A hook change without a harness case is a change without a test. Add the
case in the same commit.

### Where to make a change

`core/` is the source of truth. Everything under `.claude/`, `.codex/`,
`.cursor/` and friends in an installed repo is generated. If you find
yourself editing generated output, the fix belongs in `core/` or in the
adapter that wrote it.

An adapter is one bash script that reads `core/` and writes an agent's
native config. `adapters/README.md` explains the contract and the hook
format. Adding an agent is usually 60 to 120 lines.

### House style

The doctrine applies to this repo too:

- No new file over 400 lines without a `PRINCIPLES: max-lines-exception:`
  comment saying why.
- Hooks fail open. A crash, a timeout, or malformed input allows the
  action. A guardrail that blocks work when it breaks gets uninstalled,
  and then it guards nothing.
- Bash that runs on macOS, Linux, and Windows Git Bash. No GNU-only sed or
  awk extensions; the macOS leg has already caught one of those.
- No em dashes or en dashes in prose. Commas, periods, colons, parentheses.
- Say what you did not do as explicitly as what you did.

### Commits

The push gate wants a trailer on HEAD:

```
Senior-Checklist: ambiguity=pass summary=pass concurrency=n/a regression=pass blast=green
```

Grades are `pass`, `miss`, or `n/a`; `blast` also takes `green` or `red`.
It is a ten second self-check before the one irreversible action. If you
are working in a fork without the hooks installed, add it anyway or I will
ask you to.

### What I will probably say no to

- A dependency. Bash and git is the whole runtime, and that is a feature.
- An adapter for an agent whose hook contract is not publicly documented.
  Guessing at a payload shape produces a guard that silently never fires.
- Making a fail-open hook fail closed.
- A profile whose commands you have not run.
