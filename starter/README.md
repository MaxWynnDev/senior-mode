# senior-mode starter

The smallest setup that makes a coding agent behave like a senior
engineer instead of an eager intern. Everything installs globally under
your agent's home directory, so it applies in every repo with no
per-project work.

Five minutes to install. Nothing here touches git, deploys, or your
project files.

![Install, open a repo, first prompt gets the senior check](../docs/starter.gif)

## What you get

| Piece | What it does |
|---|---|
| The behavioral core (`CLAUDE.md` for Claude Code, `AGENTS.md` for everyone else) | senior-engineer bar, ask-when-ambiguous, evidence before code, never cite an unread source, one-pass thoroughness, never weaken a test to get green. Loaded every turn. |
| `senior-check-before.sh` | fires on every prompt: injects the "ambiguity? evidence? name the 100% version" checklist at the decision moment, so it is applied rather than merely remembered. |
| `senior-check-after.sh` | fires once at the end of every turn: "did you cut corners, would a senior push back, could your green have gone red?" The agent fixes it before you see the answer. |
| `ENGINEERING-PRINCIPLES.md` | the operating doctrine: never / always lists, money / PII / multi-tenant invariants, security defaults, a 400-line file budget, a refactor-risk model, and "how a review lies to itself". |
| `PROMPTING-CODING-AGENTS.md` | how to brief an agent so it does the right thing the first time. Read once. The single highest-leverage thing in this folder. |
| `/review` | a fast pass over your current diff for bugs, access-control slips, money/data hazards, and leftover debugging. |

## Install

Requirements: your agent's CLI, `git`, and `bash` on PATH (macOS and
Linux have it; on Windows install Git for Windows and run this from Git
Bash).

```bash
bash install.sh                          # Claude Code (default)
bash install.sh --agent codex            # or cursor, gemini, copilot, opencode
bash install.sh --agent all --dry-run    # show what would happen for every agent
```

The installer never overwrites: an existing file that differs gets the
new version beside it as `<file>.starter`. Merge by hand, or open the
file in your agent and ask it to merge.

Then open any repo. Your first prompt should carry `[SENIOR CHECK |
BEFORE]`. If nothing fires on Windows, `bash` is not on PATH.

## Per agent

| Agent | Where it lands | Hooks | Notes |
|---|---|---|---|
| Claude Code | `~/.claude/` | native (`UserPromptSubmit`, `Stop`) | the AFTER check blocks the turn once |
| Codex CLI | `~/.codex/` | native (`~/.codex/hooks.json`, same format) | run `/hooks` once to approve; if you already have a `hooks.json`, merge the `.starter` |
| Cursor | `~/.cursor/` | via the shim: BEFORE at `sessionStart`, AFTER at `stop` | User Rules are not a file in Cursor: paste `~/.cursor/senior-mode/AGENTS.md` into Settings > Rules once |
| Gemini CLI | `~/.gemini/` | via the shim: `BeforeAgent`, `AfterAgent` (system message) | `GEMINI.md` carries the core |
| Copilot CLI | `~/.copilot/` | native (`~/.copilot/hooks/senior-mode.json`) | `copilot-instructions.md` carries the core |
| OpenCode | `~/.config/opencode/` | plugin: BEFORE via the system-prompt transform | no turn-end check available |

Every other agent that reads `AGENTS.md` (Windsurf, Kiro, Amp, Zed, Warp,
Jules, Junie, Cline, Factory, Devin, Augment): copy `AGENTS.md` to its
global instructions location (see `adapters/README.md` in the full kit);
the checks become instructions rather than hooks.

## Tune it

- The end-of-turn check costs one extra short model round per turn. If
  it feels like nagging, delete the `Stop` / `stop` / `AfterAgent` block
  from the installed hooks file.
- The "User-facing copy" section is a personal style preference. Delete
  it if it is not yours.
- Each repo should still get its own short `AGENTS.md` (stack, build and
  test commands, deploy model, things you deliberately do NOT have). The
  full kit's `install.sh` writes one from a template and picks the stack
  from the manifests.
- `ENGINEERING-PRINCIPLES.md` ships with defaults for a multi-tenant web
  app that handles money and sensitive data. Sections 5, 6, and 7 say
  "delete if not applicable".

## Read next

`PROMPTING-CODING-AGENTS.md`. Seriously. Most "the agent is being dumb"
moments are missing one of the five elements it describes.
