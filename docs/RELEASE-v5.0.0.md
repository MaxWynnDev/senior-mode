One core, adapters for nine agents, and a stack picker.

senior-mode started as a Claude Code setup. This release makes the agent an
implementation detail: the doctrine, hooks, rules, reviewers, and procedures
live in one place, and a small generator writes each agent's native wiring.

## Install

```bash
git clone https://github.com/MaxWynnDev/senior-mode
bash senior-mode/install.sh --dry-run /path/to/your-repo   # see what would happen
bash senior-mode/install.sh /path/to/your-repo             # agents auto-detected, stack detected from manifests
```

Or the five minute global version, no repo required:

```bash
bash senior-mode/starter/install.sh --agent codex
```

Then paste `.senior-mode/KICKOFF-PROMPT.md` into your agent.

## What is in it

**The checks fire at the decision moment.** A prompt-submit hook injects the
senior checklist as each prompt arrives. A stop hook blocks the turn once so
the model audits its own diff before you see it, including "for every green
check you are about to report, what would RED have looked like, and could
this run have produced it?"

**The gates are mechanical.** `git push` is denied unless HEAD carries a
five-key self-check trailer. `git commit` is denied for a bare TODO, a print
debug line in a prod path, or a new source file over 400 lines without a
stated exception. Piping a CI watcher through `tail` is denied, because the
pipe's exit code replaces the run's.

**Parallel sessions do not tangle.** A session registry knows who else is
live in a checkout, across agents. Later sessions are steered to a worktree
and blocked from committing until they isolate.

**The stack is picked from evidence.** `stacks/detect.sh` scores each
profile's signals against the manifests and prints the ranked evidence.
Seven profiles ship (Next.js + Vercel + Postgres, Node API, FastAPI, Django,
Rails, Go, Rust), each with the sanctioned commands in `profile.json` so the
agent stops guessing how to run tests or migrate.

## Agents

Adapters generate native wiring for Claude Code, Codex CLI, Cursor, Gemini
CLI, GitHub Copilot, OpenCode, Factory Droid, Devin CLI, and Augment.
Anything else that reads `AGENTS.md` gets the doctrine, the rules, and the
procedures as instructions.

The Claude Code hook JSON turned out to be a de facto standard: Codex,
Copilot, Factory, Devin, Augment, and Junie speak it natively, so the same
bash scripts run unchanged. Cursor and Gemini get a 60 line shim in each
direction. OpenCode gets a plugin.

`adapters/README.md` is the capability matrix, including what each agent
cannot do. Cursor cannot inject context on prompt submit, so the before
check moves to session start. Gemini has no block-and-re-prompt at turn end.
OpenCode has no turn-end hook at all.

## What is verified

Claude Code 2.1.241 and Codex CLI 0.146.0 were run end to end. The other
seven adapters follow their agent's documented format and pass the harness,
but I have not sat inside those agents; the README says so, and the
adapter-report issue template exists for exactly that.

The harness is 60 cases against scratch git repos, running on Linux, macOS,
and Windows on every push. It earned its keep on the first CI run: a sed
regex in the shims used GNU-only alternation, so on BSD sed every field came
back empty and an allow turned into a deny. Linux and Windows were green.

The two senior checks are prompts, not guarantees. The commit and push gates
are the only hard blocks. This makes the sloppy reading rarer and visible,
not impossible.

## Requirements

`bash` and `git`. Git Bash on Windows. No other dependencies.

MIT.
