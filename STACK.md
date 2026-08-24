# Stack: detected, then picked, never assumed

The core of senior-mode is stack-neutral. Every hook, reviewer, procedure,
and doctrine doc works on any language and any deploy target, because
they operate on git, files, and shell, and on principles (auth first,
tenant from the session, integer money, additive migrations) rather than
on any framework's API.

What IS opinionated ships as a **stack profile** under `stacks/`. A
profile is an overlay: concrete rules with real helper names, a
`profile.json` with the sanctioned commands, a concrete `WORKFLOW.md`,
optional procedures, and optionally a QA pack. Installing one is
explicit (`install.sh --stack <name>`) or the result of a confident
detection (`--stack auto`, the default).

## The rule the agent follows

1. **Detect first.** `bash .senior-mode/stacks/detect.sh` reads the
   manifests, lockfiles, and deploy configs and scores every profile's
   signals. It prints the ranked evidence and a verdict (`DETECTED`,
   `CANDIDATES`, `UNKNOWN`, `GREENFIELD`). Nothing about the stack is
   said before that output exists.
2. **An existing project keeps its stack.** A `DETECTED` profile is
   installed because the repo already is that stack. `CANDIDATES` means
   weak signals: show the evidence and ask. `UNKNOWN` means the core
   adapts to the project with no profile: placeholders get the project's
   real commands, inapplicable reviewers are deleted, and the adapt-to-
   yours table below says what to change per piece. Nothing in the kit
   may contradict a working project.
3. **A greenfield project gets the picker.** `bash
   .senior-mode/stacks/detect.sh --list` prints one card per profile
   (what it is for, what it is not for). The agent walks through them,
   recommends with the reasons from the profile's `README.md`, and the
   user decides.
4. **The profile's commands are the sanctioned ones.** Once a profile is
   installed, `.senior-mode/stacks/<name>/profile.json` is where the
   agent reads how to install, run, test, lint, typecheck, and migrate.
   It does not invent alternatives.

The full mechanism, the file layout of a profile, and how to write your
own: `stacks/README.md`.

## Profiles that ship

| Profile | For | Notable |
|---|---|---|
| `nextjs-vercel-postgres` | a new full-stack web app | the reference profile: staging on demand, the QA pack, the AI paved road |
| `node-api-postgres` | a TypeScript backend API or service (Hono, Fastify, Express, Nest) | must not fire on a Next.js repo, and does not |
| `python-fastapi-postgres` | a Python API or service | uv, SQLAlchemy 2, Alembic, ruff, pyright |
| `django-postgres` | a data-heavy product where the admin and the ORM earn their keep | `makemigrations --check` in CI, forward-only prod migrations |
| `rails-postgres` | a Rails 7.2/8 app | Kamal 2, strong_migrations, Hotwire |
| `go-service` | a backend where one static binary and inspectable SQL matter | pgx + sqlc, goose or atlas |
| `rust-service` | an axum + sqlx service | compile-time checked queries, offline query cache |

Run `bash stacks/detect.sh --list` for the live cards.

## Adapting the core to a stack with no profile

Everything below the doctrine line is a placeholder or a profile. When a
project is on something else (PHP, Elixir, Kotlin, a monorepo of several
of these), this is what to change per piece; "keep" means no change.

| Kit piece | What to adapt |
|---|---|
| Hooks (`.senior-mode/hooks/`) | keep; `post-edit-format.sh` auto-detects biome, prettier, ruff, black, gofmt, rustfmt, deno fmt; set `SENIOR_MODE_FORMAT_CMD` for anything else |
| `pre-commit-audit.sh` source extensions | add yours to the list if missing |
| `conventions-sweeper` date check | replace with your language's date trap, or delete |
| `tenant-isolation-reviewer` | keep; name your ORM's scoping helper |
| `money-path-reviewer` | keep (integer minor units at rest in every language) |
| `migration-reviewer` | name your migration tool and what its watermark is |
| `app-verifier` boot recipe | your dev command |
| Core rules (`.senior-mode/rules/`) | keep; set the path globs for your layout (the SETUP comment at the top of each) |
| `migration-ritual` | your runner behind a confirming wrapper |
| `incident`, `standup` deploy step | your platform's CLI |
| `stage`, `qa-sweep`, QA pack | only in the reference profile; rebuild on your DB's branching and your e2e runner, or skip |
| `WORKFLOW.md` | rewrite the pipeline diagram; keep the sections |
| `full-audit.mjs` (Claude Code) | keep; the dimensions are stack-neutral |

Two things never change across stacks: the doctrine docs
(`ENGINEERING-PRINCIPLES.md`, `PROMPT-STANDARD.md`, `PROMPTING.md`) and
the git-level hooks. They are the kit.

## Writing a profile

Copy the closest profile to `stacks/<your-name>/`, keep the same files,
rewrite `detect.txt` so your repo scores 20+ and its neighbours score
under 10, fill `profile.json` with real commands only, and document the
assumptions at the top of its `README.md`. `install.sh --stack <your-name>`
overlays it the same way.
