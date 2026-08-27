# Adapters: one core, every agent

`core/` is the source of truth (hooks, rules, reviewers, commands,
memory). An adapter is a small generator that writes an agent's native
wiring into a target repo, pointing back at `.senior-mode/`. Nothing in
`core/` knows which agent is running it.

```
bash install.sh --agent claude,cursor <repo>     # explicit
bash install.sh --agent auto <repo>              # config dir in the repo, or CLI on PATH
bash install.sh --agent all <repo>               # every adapter (slow on Windows Git Bash)
bash adapters/<agent>/generate.sh <repo>         # one adapter by hand (SM_STACK=<profile> to overlay a stack)
```

## The canonical hook contract

Every script in `core/hooks/` reads the Claude Code hook JSON on stdin
(`session_id`, `hook_event_name`, `tool_name`, `tool_input.command` /
`tool_input.file_path`, `prompt`, `stop_hook_active`) and writes the
Claude Code hook JSON on stdout (`hookSpecificOutput.permissionDecision`
+ `permissionDecisionReason`, `hookSpecificOutput.additionalContext`,
`decision: block` + `reason`). Exit 0 always: a broken hook allows.

That contract turned out to be the industry's de facto standard. As of
August 2026 it is spoken natively (event names, `matcher`, `hooks[]`,
`type: command`) by **Claude Code, Codex CLI, GitHub Copilot (CLI, cloud
agent, VS Code), Factory Droid, Devin CLI, and Augment**.
For those, the adapter only picks the file name and the repo-root
expression. **Cursor** and **Gemini CLI** have their own event names and
stdout shapes, so a shim (`adapters/shims/`) translates in both
directions. **OpenCode** has no shell-hook config; its plugin API runs
the same scripts from TypeScript.

The hooks resolve the repo root from, in order: `SENIOR_MODE_PROJECT_DIR`,
`CLAUDE_PROJECT_DIR` (Cursor and Gemini export this as an alias),
`CURSOR_PROJECT_DIR`, `GEMINI_PROJECT_DIR`, then the current directory.

## Capability matrix

What each adapter can wire, and what it cannot. "Native" means the
agent's own mechanism carries the feature; "instruction" means the
behaviour is asked for in `AGENTS.md` rather than enforced.

| Agent | Entry file | Hooks: gates (commit/push/pipe) | BEFORE check | AFTER check | Formatter | Path-scoped rules | Reviewers | Commands |
|---|---|---|---|---|---|---|---|---|
| Claude Code | `CLAUDE.md` → `@AGENTS.md` | native | native (UserPromptSubmit) | native (Stop, block once) | native (PostToolUse) | `.claude/rules` `paths:` | `.claude/agents` | `.claude/commands` |
| Codex CLI | `AGENTS.md` (root + nested) | native `.codex/hooks.json` | native | native | native | instruction (nested AGENTS.md optional) | `.codex/agents/*.toml` | `.agents/skills` |
| Cursor | `AGENTS.md` (root + nested) | shim: `beforeShellExecution` | `sessionStart` context (once per session) | `stop` → follow-up message, once per turn | `afterFileEdit` | `.cursor/rules/*.mdc` globs | `.cursor/agents` | `.agents/skills` |
| Gemini CLI | `AGENTS.md` via `context.fileName` | shim: `BeforeTool` (`run_shell_command`) | `BeforeAgent` context | `AfterAgent` deny (block once, re-prompt) | `AfterTool` | instruction | `.gemini/agents` | `.gemini/commands/*.toml` + skills |
| Copilot | `AGENTS.md` + `.github/copilot-instructions.md` | native `.github/hooks/*.json` (PascalCase events) | native | native (`Stop`) | native | `.github/instructions` `applyTo` | `.github/agents/*.agent.md` | `.agents/skills` |
| OpenCode | `AGENTS.md` (root, nested lazily) | plugin: `tool.execute.before` throws | system-prompt transform | not available | `tool.execute.after` | `instructions` glob (always loaded) | `.opencode/agents` | `.opencode/commands` + skills |
| Factory Droid | `AGENTS.md` | native `.factory/hooks.json` | native | native | native | instruction | `.factory/droids` | `.factory/commands` + skills |
| Devin CLI | `AGENTS.md` | native `.devin/hooks.v1.json` | native | native | native | `.devin/rules` (`glob` / `model_decision`) | instruction | `.agents/skills` |
| Augment | `AGENTS.md` | native `.augment/settings.json` | native | native | native | `.augment/rules` (`agent_requested`) | instruction | `.augment/commands` + skills |
| Windsurf, Kiro, Amp, Zed, Warp, Jules, Junie, Cline | `AGENTS.md` | not wired (see notes) | instruction | instruction | not wired | instruction | instruction | `.agents/skills` where read |
| Aider | none by default | no | instruction (add `read: [AGENTS.md]` to `.aider.conf.yml`) | | | | | |

Notes on the last two rows: Windsurf has a `.windsurf/hooks.json` with a
different stdin shape (`tool_info`), Kiro has `.kiro/hooks/*.json` with an
undocumented stdin contract, Junie's hooks are user-level only
(`~/.junie/config.json`), Cline's shell-hook contract is undocumented,
Amp's hooks are TypeScript plugins. All of them read `AGENTS.md`, and
most read `.agents/skills`, so the posture, rules, and procedures reach
them; the mechanical gates do not. Contributions welcome: an adapter is
one bash script.

## Where the universal pieces go

| Piece | Location in the target repo | Read by |
|---|---|---|
| Posture, rules table, procedures, reviewers, stack | `AGENTS.md` | every agent above except Claude Code, which imports it from `CLAUDE.md` |
| Hooks, rules, reviewers, commands, memory (source) | `.senior-mode/` | the adapters, and agents via instruction |
| Procedures as Agent Skills | `.agents/skills/<name>/SKILL.md` | Cursor, Codex, Gemini, Copilot, OpenCode, Amp, Zed, Warp, Junie, Factory, Augment, Devin CLI |
| Doctrine | `ENGINEERING-PRINCIPLES.md`, `PROMPT-STANDARD.md`, `PROMPTING.md`, `WORKFLOW.md` | every agent, by reference from `AGENTS.md` |

`AGENTS.md` is kept under ~8 KB on purpose: Codex caps combined
project docs at 32 KiB, and every agent pays for it on every turn.

## Verifying an adapter

`core/hooks/test-checklist.sh` covers the hooks, both shims (Cursor and
Gemini payloads in and out), the stack detector, and an install into a
scratch repo. Run it after touching anything under `core/` or
`adapters/`. The generated JSON is validated in CI with Node when it is
available.
