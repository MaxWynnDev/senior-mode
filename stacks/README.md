# Stack profiles and the picker

The core of senior-mode is stack-neutral: hooks, doctrine, reviewers, and
procedures operate on git, files, shell, and principles. Everything
framework-specific ships as a **profile** under `stacks/<name>/`, and the
agent picks one from evidence, not memory.

## How the pick happens

1. **Detect.** `bash stacks/detect.sh <repo>` scores every profile's
   signals (`stacks/<name>/detect.txt`: manifests, config files, dependency
   names) against the repository and prints the ranked evidence plus a
   verdict:
   - `DETECTED: <name>`: a confident match (score 20+). `install.sh --stack
     auto` installs it.
   - `CANDIDATES`: weak signals. Nothing is installed; the kickoff shows the
     evidence and asks you.
   - `UNKNOWN`: manifests exist but no profile matches. The core adapts to
     the project without a profile (`STACK.md`, the adapt-to-yours table).
   - `GREENFIELD`: no manifest at all. The kickoff presents the picker.
2. **Pick.** `bash stacks/detect.sh --list` prints one card per profile
   (what it is for, what it is not for). On a greenfield repo the kickoff
   walks through the cards and recommends `nextjs-vercel-postgres` for a
   web app, `python-fastapi-postgres` or `go-service` for a service, with
   the reasons in each profile's `README.md`. You decide.
3. **Install.** `bash install.sh --stack <name> <repo>` (or re-run with
   `--stack` after the pick). The profile's rules replace the core rules
   for the same layer, its commands are added, its `WORKFLOW.md` becomes
   the pipeline doc, and `.senior-mode/stacks/<name>/profile.json` becomes
   the source of the sanctioned commands (install, dev, test, lint,
   typecheck, migrate). Agents read that file instead of guessing.

## What a profile contains

| File | Purpose |
|---|---|
| `detect.txt` | detection signals with weights (`file`, `glob`, `grep`) |
| `profile.json` | the card (title, recommended_for, not_for) and the facts: commands, layout globs, LOC budgets, migration tool, which reviewers apply, how the app-verifier boots the app |
| `README.md` | assumptions, platform notes, what to adapt for sibling frameworks |
| `WORKFLOW.md` | the concrete deploy pipeline and migration-runner properties |
| `rules/*.md` | path-scoped rules with real helper names (Claude frontmatter `paths:`; other adapters derive their own scoping from it) |
| `commands/*.md` | optional stack procedures (e.g. `stage`, `qa-sweep`) |
| `qa/` | optional QA pack (page sweep, staging scripts, seed checklist) |

## Profiles that ship

Run `bash stacks/detect.sh --list` for the live cards. Today:
`nextjs-vercel-postgres` (the reference web-app profile, with the QA
pack), `node-api-postgres`, `python-fastapi-postgres`, `django-postgres`,
`rails-postgres`, `go-service`, `rust-service`.

## Writing your own

Copy the closest profile to `stacks/<your-name>/`, keep the same files,
rewrite `detect.txt` so your repo scores 20+ and its neighbours score
under 10, fill `profile.json` with real commands only, and document the
assumptions at the top of its `README.md`. `install.sh --stack <your-name>`
overlays it the same way. A profile is a good pull request.
