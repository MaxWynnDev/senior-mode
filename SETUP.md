# Setting up senior-mode in a project

The install in detail, what each piece does, per-agent notes, and how to
tune it. Quick version: `START-HERE.md`.

## 1. Install

```bash
bash install.sh [--agent <list|auto|all|none>] [--stack <name|auto|none>] [--dry-run] [--force] <repo>
```

What lands where:

| Path in your repo | What | Who reads it |
|---|---|---|
| `.senior-mode/hooks/` | the hook scripts and the test harness | every adapter's wiring points here |
| `.senior-mode/rules/` | the stack-neutral rules (and the profile's rules when a stack is installed) | adapters copy or transform them; `AGENTS.md` points here for agents without scoping |
| `.senior-mode/reviewers/` | the six review briefs | adapters turn them into subagents |
| `.senior-mode/commands/` | the fifteen procedures | adapters turn them into commands and skills |
| `.senior-mode/memory/` | the working-style memory bundle | Claude Code moves it into auto-memory; others read the index |
| `.senior-mode/adapters/` | the Cursor and Gemini shims | their hooks |
| `.senior-mode/stacks/` | `detect.sh`, every profile's card and signals, the installed profile in full | the kickoff's picker; the agent reads `profile.json` for commands |
| `.senior-mode/KICKOFF-PROMPT.md`, `SETUP.md`, `STACK.md`, `stacks/README.md` | the docs you paste or read | you |
| `AGENTS.md` | the universal entry point | every agent except Claude Code, which imports it |
| `CLAUDE.md` | `@AGENTS.md` + Claude Code notes | Claude Code |
| `ENGINEERING-PRINCIPLES.md`, `PROMPT-STANDARD.md`, `PROMPTING.md`, `WORKFLOW.md` | the doctrine | every agent, by reference |
| `.agents/skills/<name>/SKILL.md` | procedures as Agent Skills | Cursor, Codex, Gemini, Copilot, OpenCode, Amp, Zed, Warp, Junie, Factory, Augment, Devin CLI |
| `.claude/`, `.codex/`, `.cursor/`, `.gemini/`, `.github/`, `.opencode/`, `.factory/`, `.devin/`, `.augment/` | per-agent wiring | that agent |

Rules: a file that does not exist is written; byte-identical is skipped;
different is left alone and the new version goes beside it as
`<file>.senior-mode`, listed under MERGE at the end. Nothing is deleted.
`--force` overwrites.

`--agent auto` picks agents that have a config dir in the repo or a CLI
on PATH (`claude`, `codex`, `agent`/`cursor-agent`, `gemini`, `copilot`,
`opencode`, `droid`, `devin`, `auggie`). `--stack auto` runs the detector
and installs a profile only on a confident match.

## 2. Kickoff

Open your agent in the repo and paste `.senior-mode/KICKOFF-PROMPT.md`.
It confirms the wiring, confirms or picks the stack, merges
`.senior-mode` files, fills placeholders, moves memory (Claude Code),
scopes rules, deletes inapplicable reviewers, runs the harness.

## 3. The hooks

All hooks fail open: a crash or a timeout allows. Every one reads the
Claude Code hook JSON on stdin and writes it on stdout; the adapters
map that to each agent (see `adapters/README.md`).

| Hook | Event | What it does |
|---|---|---|
| `session-registry.sh` | SessionStart (`register`), prompt (`touch`), SessionEnd (`unregister`) | Registers a heartbeat for every live session, whichever agent, and tells each one who else is active on what tree, branch, and HEAD. Later sessions in a shared checkout are steered to a worktree. Warns when HEAD shares no ancestor with the mainline. Silent when alone. Mainline from origin's HEAD; override with `SENIOR_MODE_MAINLINE`. |
| `session-tree-guard.sh` | PreToolUse Bash | BLOCKS commit, push, merge, rebase from a shared checkout for a non-incumbent session. One-shot override: `SENIOR_MODE_ALLOW_SHARED_GIT=1`. |
| `senior-check-before.sh` | prompt submit | Injects the BEFORE checklist (ambiguity, 100% version, evidence, never cite unread) at the decision moment. |
| `ultracode-advisor.sh` | prompt submit | Nudges toward a multi-agent verification pass when the prompt or the working diff hits money, migrations, auth, PII, security, or a large refactor. Advisory. |
| `pre-commit-audit.sh` | PreToolUse Bash | DENIES a commit with a bare `TODO`/`FIXME`, a `console.log` in a prod path, or a new source file over 400 LOC without a `PRINCIPLES: max-lines-exception:` comment. Self-filters to git commit commands. |
| `pre-push-checklist.sh` | PreToolUse Bash | DENIES a push unless HEAD carries the `Senior-Checklist:` trailer with all five keys graded. Validates the repo the push runs FROM. |
| `exit-code-mask-guard.sh` | PreToolUse Bash | DENIES piping a CI watcher through `tail`/`head`/`grep` (the pipe's exit code replaces the run's). The deny message has the redirect recipe. |
| `post-edit-format.sh` | PostToolUse Write/Edit | Formats the edited file with biome, prettier, ruff, black, gofmt, rustfmt, or deno fmt (auto-detected, project-local first), or `SENIOR_MODE_FORMAT_CMD`. |
| `senior-check-after.sh` | Stop | Blocks the turn once with the AFTER checklist (corners cut? senior pushback? could the green have gone red?). Sentinel per session; `stop_hook_active` forces allow, so it can never loop. |
| `senior-verify-counterfactual.sh` (optional) | Stop | Asks a small model whether the response's `[WITHOUT HOOKS]` section is honest. Needs `ANTHROPIC_API_KEY` and `node`. Not wired by default. |
| `ship-policy.sh` (optional) | prompt submit | One-line standing reminder that behaviour changes ship through the `ship` procedure. Not wired by default. |
| `test-checklist.sh` | (harness) | Runs every case above against scratch repos, plus the shims, the detector, and an install. `bash .senior-mode/hooks/test-checklist.sh`. |

Per-agent notes:

- **Claude Code**: everything native. `[SENIOR CHECK | AFTER]` blocks the
  turn once via the Stop hook.
- **Codex CLI**: everything native (`.codex/hooks.json`). Project hooks
  load only for a trusted project and must be approved once via `/hooks`.
- **Cursor**: the shell guards run on `beforeShellExecution`; the BEFORE
  checklist arrives once per session via `sessionStart` (Cursor cannot
  inject context on prompt submit); the AFTER check uses `stop` with a
  follow-up message, once per turn.
- **Gemini CLI**: `context.fileName` makes it read `AGENTS.md`; guards on
  `BeforeTool` (`run_shell_command`); BEFORE via `BeforeAgent`; the AFTER
  check surfaces as a system message (Gemini has no block-and-re-prompt).
- **Copilot**: `.github/hooks/senior-mode.json` with PascalCase events;
  `preToolUse` is fail-closed on a non-zero exit, and the hooks always
  exit 0. Cloud honors the `bash` field only.
- **OpenCode**: the plugin runs the guards on `tool.execute.before` and
  denies by throwing; `opencode.json` also carries declarative `bash`
  permission gates for `git push`.
- **Factory, Devin, Augment**: native; file names differ.
- **Everything else**: `AGENTS.md` carries the posture and asks for the
  same checks as instructions; no mechanical gate.

## 4. Reviewers and procedures

Reviewers (`.senior-mode/reviewers/`): `conventions-sweeper` (brand, copy,
dates, LOC, orphaned tests; cheap model), `tenant-isolation-reviewer`,
`money-path-reviewer`, `migration-reviewer`, `prompt-auditor` (LLM call
sites vs `PROMPTING.md`), `app-verifier` (boots the app and drives the
changed flows; fill its boot recipe from `profile.json`). Delete the ones
whose domain your repo lacks; the kickoff asks.

Procedures (`.senior-mode/commands/`, wired as slash commands and as
Agent Skills): `go`, `ship`, `iterate`, `review`, `pre-push`, `worktree`,
`learn`, `techdebt`, `incident`, `standup`, `loc-budget`, `tenant-audit`,
`migration-ritual`, `audit-prompt`, `new-ai-feature`; the reference
profile adds `stage` and `qa-sweep`. Agents without subagents run the
reviewer briefs as checklists inside `pre-push`.

## 5. Tuning

- LOC threshold and source extensions: `pre-commit-audit.sh`.
- Checklist keys and grades: `pre-push-checklist.sh` (keep the parser and
  key list in sync).
- High-stakes signals: `ultracode-advisor.sh`.
- Session TTL: `SENIOR_MODE_SESSION_TTL_MIN` (default 45).
- Formatter: `SENIOR_MODE_FORMAT_CMD`.
- The AFTER check: delete the Stop event from your agent's wiring if the
  extra round per turn is not worth it.
- Rules scoping: the SETUP comment at the top of each rule shows the
  globs; the adapters derive `globs:` / `applyTo:` from it.

After editing anything under `.senior-mode/`, re-run `install.sh` to
regenerate the wiring, and `bash .senior-mode/hooks/test-checklist.sh`
to prove nothing broke.
