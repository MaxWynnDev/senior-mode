# senior-mode: how to work in this repo

This repo runs its own kit. The instructions below are the filled-in
version of the template it ships (`core/AGENTS.md`), which is what gets
installed into other people's projects.

You are operating in senior mode. The bar for every change: would a senior
engineer approve this diff, or call it a patch? Clear it unprompted.

## Before you touch anything

1. **Ambiguity trigger.** If the directive has two reasonable readings that
   produce different behaviour, ask, citing the alternative reading. One
   clarifying question at the start is not an approval loop.
2. **Evidence before code.** For any non-trivial edit or commit, lead with:

   ```
   [BEFORE-AUDIT]
   - Diagnosis: <hypothesis + the evidence it rests on>
   - Missing evidence: <what would confirm it; if "none needed", justify>
   - 100% version: <named>
   - 80% gap: <what I would skip and why>
   - Senior would reject if: <specific failure mode>
   - Action: <confirm-first | ship | ask>
   ```
3. **Never cite an unread source.** If you cannot point at the tool call
   that opened a file, run, or URL, it does not go in the message.
4. **Read `ENGINEERING-PRINCIPLES.md`** before non-trivial work. Sections 3
   and 4 are non-negotiable, 12a is the 400-line budget, 19 is how a review
   lies to itself.

## Before you say "done"

- Run the harness. `bash core/hooks/test-checklist.sh` must print
  `ALL CASES [ok]`. A hook change without a harness case is untested.
- Say what RED would have looked like for every green you report, and
  whether this run could have produced it.
- Never weaken a check to get green. If the check is wrong, say so with
  evidence and stop; changing the oracle is a human decision.
- State what you did NOT do as explicitly as what you did.

## What this repo is

A portable engineering setup for coding agents. `core/` is the source of
truth; a per-agent adapter generates native wiring from it. There is no
build step, no package manager, and no dependency beyond bash and git.

```
core/            hooks, rules, reviewers, commands, memory, and the AGENTS.md
                 and CLAUDE.md templates that ship to users
adapters/        one generator per agent, plus the Cursor and Gemini shims
stacks/          detect.sh, the picker, and seven stack profiles
starter/         the five minute global install, per agent
docs/            the README GIFs and the script that renders them
install.sh       the non-clobbering installer
```

## Rules by path

| Touching | Read first | And then |
|---|---|---|
| `core/hooks/*.sh` | `CONTRIBUTING.md` (house style), `SECURITY.md` (the fail-open rule) | add a harness case in the same commit |
| `adapters/**` | `adapters/README.md` (the hook contract and the capability matrix) | run the harness; it covers both shims |
| `stacks/**` | `stacks/README.md`, `CONTRIBUTING.md` (the two hard rules for a profile) | test `detect.sh` against a neighbouring stack, not just yours |
| `core/rules/*.md`, `core/reviewers/*.md`, `core/commands/*.md` | the existing files; match their voice exactly | regenerate wiring if the frontmatter shape changed |
| `README.md`, `docs/` | the "What is verified" section; do not let a claim drift past it | re-render GIFs with `python docs/make-gifs.py docs` if you changed a script |

## Commands

```bash
bash core/hooks/test-checklist.sh                  # the harness, 60 cases (~3 min on Windows)
bash install.sh --dry-run --agent all /tmp/scratch # what an install would write
bash stacks/detect.sh --list                       # the stack picker cards
bash stacks/detect.sh <repo>                       # score a repo against the profiles
python docs/make-gifs.py docs                      # re-render the README GIFs (needs Pillow)
```

## Hard constraints

- **Bash and git only.** No runtime dependency, ever. Python is for the GIF
  renderer, which is documentation, not product.
- **Portable bash.** macOS, Linux, and Windows Git Bash. No GNU-only sed or
  awk extensions. The macOS CI leg has already caught one of those, and it
  was silent on the other two platforms.
- **Hooks fail open.** A crash, timeout, or malformed payload allows the
  action. A guardrail that blocks work when it breaks gets uninstalled.
- **Every command in a `profile.json` must be one that has been run.** A
  wrong migrate command is worse than no profile.
- **No new file over 400 lines** without a `PRINCIPLES: max-lines-exception:`
  comment in the first 20 lines saying why.

## What this repo deliberately does NOT have

Dependencies, a package manager, a build step, a test framework beyond the
bash harness, feature flags, a staging environment, and pull requests.
Changes go to `main`; CI runs the harness on three platforms and that is
the gate. Do not propose adding any of these unless asked.

## Claims and honesty

`README.md` has a "What is verified, and what is not" section. Claude Code
and Codex CLI were run end to end; the other seven adapters follow their
documented formats and pass the harness but have not been exercised inside
those agents. Any change that would make the README claim more than that
has to update that section in the same commit.

## Copy

The product name is **senior-mode**, lowercase, hyphenated. In prose and in
user-facing strings: no em dashes, no en dashes, no hyphens as punctuation.
Commas, periods, colons, parentheses. No corporate filler.

## Commits

Push is denied unless HEAD carries the trailer:

```
Senior-Checklist: ambiguity=pass summary=pass concurrency=n/a regression=pass blast=green
```

Do not add `Co-Authored-By` or session links to commits in this repo.
