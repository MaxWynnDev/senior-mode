@AGENTS.md

<!-- senior-mode: Claude Code does not read AGENTS.md on its own; the import
line above pulls it in. Everything universal lives there. Only Claude
Code-specific notes belong below. Keep this file short. -->

## Claude Code specifics

- Hooks are wired in `.claude/settings.json` and run the scripts in
  `.senior-mode/hooks/` (they fail open; a broken hook never blocks work).
  `[SENIOR CHECK | BEFORE]` arrives with every prompt; `[SENIOR CHECK |
  AFTER]` blocks the turn once so you self-audit before answering. Push is
  denied without the `Senior-Checklist:` trailer; commit is denied for a
  bare `TODO`, a `console.log` in a prod path, or a new file over 400 LOC
  without a `PRINCIPLES: max-lines-exception:` comment.
- Slash commands (`.claude/commands/`) are the procedures listed in
  AGENTS.md: `/go`, `/ship`, `/iterate`, `/review`, `/pre-push`,
  `/worktree`, `/learn`, `/techdebt`, `/incident`, `/standup`,
  `/loc-budget`, `/tenant-audit`, `/migration-ritual`, `/audit-prompt`,
  `/new-claude-feature`<!-- , `/stage`, `/qa-sweep` (stack profile) -->.
- Subagents (`.claude/agents/`) are the reviewers; `/pre-push` fans them
  out in parallel. Delete the ones whose domain this repo lacks.
- Path-scoped rules live in `.claude/rules/` with `paths:` frontmatter
  (fill in the globs from the SETUP comment at the top of each file).
- Parallel sessions: `SessionStart` registers this session; a later
  session in the same checkout is steered to `/worktree` and blocked from
  committing until it isolates. Override a single command with
  `SENIOR_MODE_ALLOW_SHARED_GIT=1` only when the flagged peer is dead.
- Multi-agent audits: `.claude/workflows/full-audit.mjs` (the Workflow
  tool). `.senior-mode/hooks/ultracode-advisor.sh` nudges toward it when a
  prompt or the diff hits money, tenancy, migrations, PII, or security.
- Memory: the kickoff moves `.senior-mode/memory/*.md` into this repo's
  auto-memory directory (`~/.claude/projects/<project>/memory/`).
- Operating posture: strongest model at high effort for judgment; delegate
  mechanical fan-out to cheaper subagents via `model`; `/fast` only for
  mechanical turns.
