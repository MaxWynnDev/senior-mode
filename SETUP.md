# Setting up senior-mode in a project

The install in detail, what each piece does, per-agent notes, and how to
tune it. Quick version: `START-HERE.md`.

## 1. Install

```bash
bash install.sh [--agent <list|auto|all|none>] [--stack <name|auto|none>] [--dry-run] [--upgrade] [--force] <repo>
```

What lands where:

| Path in your repo | What | Who reads it |
|---|---|---|
| `.senior-mode/hooks/` | the hook scripts and the test harness | every adapter's wiring points here |
| `.senior-mode/rules/` | the stack-neutral rules (and the profile's rules when a stack is installed) | adapters copy or transform them; `AGENTS.md` points here for agents without scoping |
| `.senior-mode/reviewers/` | the six review briefs | adapters turn them into subagents |
| `.senior-mode/commands/` | the sixteen procedures | adapters turn them into commands and skills |
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

To take a new kit version, run `install.sh --upgrade <repo>`. It replaces
the kit's own code where it differs: the hooks, the shims, the
procedures, and the skills, commands and workflows generated from them.
Each replaced file is saved under `.senior-mode/backup/<stamp>/` first.
Your `AGENTS.md`, `CLAUDE.md`, doctrine docs, rules, reviewers, memory
and agent settings still follow the rules above, so a changed one lands
beside yours as `<file>.senior-mode`. If you had tuned a hook, copy that
edit back from the backup. A plain re-run doesn't upgrade anything: it
keeps every file that differs.

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
| `session-registry.sh` | SessionStart (`register`), prompt (`touch`), SessionEnd (`unregister`) | Registers a heartbeat for every live session, whichever agent, and tells each one who else is active on what tree, branch, and HEAD. Later sessions in a shared checkout are steered to a worktree. Warns when HEAD shares no ancestor with the mainline. Silent when alone. Mainline from origin's HEAD; override with `SENIOR_MODE_MAINLINE`. At SessionEnd it also removes the senior-check hooks' state files for the session. |
| `session-tree-guard.sh` | PreToolUse Bash | BLOCKS commit, push, merge, rebase from a shared checkout for a non-incumbent session. One-shot override: `SENIOR_MODE_ALLOW_SHARED_GIT=1`. |
| `senior-check-before.sh` | prompt submit | Injects the BEFORE checklist (ambiguity, 100% version, evidence, never cite unread, finish in this turn) at the decision moment. Silent on a background-task notification. |
| `ultracode-advisor.sh` | prompt submit | Names the reviewer to run (`money-path-reviewer`, `tenant-isolation-reviewer`, `migration-reviewer`, or the pre-push fan-out) when the prompt or the working diff hits money, migrations, auth, PII, security, or a large refactor. Advisory. It never starts a workflow; that stays your call. |
| `pre-commit-audit.sh` | PreToolUse Bash | DENIES a commit with a bare `TODO`/`FIXME`, a `console.log` in a prod path, or a new source file over 400 LOC without a `PRINCIPLES: max-lines-exception:` comment. DENIES a new checker suppression with no reason (`@ts-ignore`, a cast to `any`, a bare `# type: ignore`, `eslint-disable`, `//nolint`), a loosened checker config (a strict flag off, `ignoreBuildErrors`, a longer tsconfig `exclude`), and staged source that fails the code check; `SENIOR_MODE_ALLOW_SYNTAX=1` in front of the commit passes a finding you can show is wrong. Self-filters to git commit commands. Audits what a chained `git add` or a `commit -a` is about to stage, through a scratch index. |
| `pre-push-checklist.sh` | PreToolUse Bash | DENIES a push unless HEAD carries the `Senior-Checklist:` trailer with all five keys graded. Validates the repo the push runs FROM. |
| `exit-code-mask-guard.sh` | PreToolUse Bash | DENIES piping a CI watcher through `tail`/`head`/`grep` (the pipe's exit code replaces the run's). The deny message has the redirect recipe. Also DENIES `\|\| true` after a type checker, linter or test runner, and `tsc` with source files beside a tsconfig (tsc ignores the tsconfig then). |
| `package-install-guard.sh` | PreToolUse Bash | Before an install of a package the repo has never used, asks npm or PyPI about the name. DENIES a name the registry doesn't have, and denies once an npm name under 300 downloads a week. Sends the name and nothing else. Needs `curl`; allows on any answer it doesn't recognise. `SENIOR_MODE_INSTALL_LOOKUP=off`. |
| `post-edit-format.sh` | PostToolUse Write/Edit | Formats the edited file with biome, prettier, ruff, black, gofmt, rustfmt, or deno fmt (auto-detected, project-local first), or `SENIOR_MODE_FORMAT_CMD`. Then runs `post-edit-check.sh` on the same file. |
| `post-edit-check.sh` | (run by the formatter hook) | Reads the edited file and BLOCKS with what it finds: an import that names nothing, a named import the module doesn't export, a call to a repo function with the wrong number of arguments, an index that is always one past the end, a syntax error. Then runs the real checker on that file inside a budget (the repo's own TypeScript, pyright or mypy, `go vet`, `cargo check`, or `commands.check_file`). Uses `node` or the project's `python` when they're there and installs nothing. |
| `check.sh` | (you or the agent run it) | `bash .senior-mode/hooks/check.sh [typecheck\|lint\|test]` runs the repo's full check with the exit code intact and writes a receipt. The Stop hook asks for it when the turn edited source and no receipt is newer than the last edit. |
| `boundary-probe.sh` | (you or the agent run it) | Flips each comparison and each `+ 1` / `- 1` on the lines a diff added, runs the tests, and reports the flips that stayed green. The `boundary` procedure wraps it. |
| `senior-check-after.sh` | Stop | Reads the final answer and blocks it when it hands back undone work ("what I didn't do", "I haven't tested", an "Open items" heading), twice at most per turn, push turns included. Blocks once per turn with the AFTER checklist (corners cut? senior pushback? could the green have gone red?) on a turn that ran a command or edited a file, and asks for the `[AFTER-AUDIT]` block. State per session; 3 blocks in one turn at most. |
| `senior-verify-counterfactual.sh` (optional) | Stop | Asks a small model whether the `Without senior mode` line of the `[AFTER-AUDIT]` block names a real catch. Needs `ANTHROPIC_API_KEY` and `node`. Not wired by default. |
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
  check is an `AfterAgent` deny, which re-prompts once. The shim passes
  `prompt_response` to the undone-work check.
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
`migration-ritual`, `audit-prompt`, `new-ai-feature`, `boundary`; the reference
profile adds `stage` and `qa-sweep`. Agents without subagents run the
reviewer briefs as checklists inside `pre-push`.

## 5. Tuning

- LOC threshold and source extensions: `pre-commit-audit.sh`.
- Checklist keys and grades: `pre-push-checklist.sh` (keep the parser and
  key list in sync).
- High-stakes signals: `ultracode-advisor.sh`.
- Session TTL: `SENIOR_MODE_SESSION_TTL_MIN` (default 45).
- Formatter: `SENIOR_MODE_FORMAT_CMD`.
- Code check: `SENIOR_MODE_SYNTAX=off` turns it off. `SENIOR_MODE_TYPECHECK=off`
  keeps the parse-level checks and drops the per-edit type check (use it
  where CI owns the typecheck). `SENIOR_MODE_TYPECHECK_BUDGET` is the
  seconds the per-edit checker gets, 20 by default.
- The commands the hooks run: `SENIOR_MODE_TYPECHECK_CMD`,
  `SENIOR_MODE_CHECK_FILE_CMD` (`{file}`, `{rel}` and `{dir}` are
  replaced), `SENIOR_MODE_TEST_CMD`, `SENIOR_MODE_TEST_RELATED_CMD`.
  Without them the hooks read `commands` in the stack profile.
- Install lookup: `SENIOR_MODE_INSTALL_LOOKUP=off`, and
  `SENIOR_MODE_INSTALL_MIN_DOWNLOADS` for the weekly floor (300).
- The AFTER check skips a turn with no command and no edit. Only shell
  and edit tools count, so a turn that only called MCP tools is skipped
  too. `SENIOR_MODE_AFTER_ALWAYS=1` runs it on every turn. Delete the Stop
  event from your agent's wiring to drop it and the undone-work check.
- The undone-work phrases: the `re_` patterns in `senior-check-after.sh`.
- Rules scoping: the SETUP comment at the top of each rule shows the
  globs; the adapters derive `globs:` / `applyTo:` from it.

After editing anything under `.senior-mode/`, re-run `install.sh` to
regenerate the wiring, and `bash .senior-mode/hooks/test-checklist.sh`
to prove nothing broke.
