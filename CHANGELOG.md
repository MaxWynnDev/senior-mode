# senior-mode changelog

## v6 (2026-11-21): the answer ends with what got done

I was getting answers that ended in a list of what the agent didn't do.
The kit was asking for that list in five places. v6 takes the ask out
and checks the final answer for it.

### The closing contract

- `AGENTS.md` (core, starter, and this repo's own): the agent finishes
  the work in the turn. A decision that's yours comes as one
  multiple-choice question, a step only a human can take comes as exact
  instructions, and a failed check is reported as failed. Non-trivial
  work closes with an `[AFTER-AUDIT]` block: `Covered` and `Without
  senior mode`.
- `[BEFORE-AUDIT]`: `80% gap: <what I would skip and why>` is now
  `Shortcut I won't take: <what an 80% pass would skip>`.
- Gone: "State what you did NOT do as explicitly as what you did"
  (`AGENTS.md`, `ENGINEERING-PRINCIPLES.md` section 14,
  `CONTRIBUTING.md`), "Name any gaps explicitly so the user sees them"
  (the after-hook), and the "what a senior would push back on" section
  of the summary (the senior-default memory). Each one now says to fix
  the thing.
- `/iterate` reports `Proves:` in place of `Residual risk:`. `/ship`
  drops "deferred findings". A capped loop ends with a multiple-choice
  question. `/techdebt` asks its two options the same way.
- New memory: `feedback_finish_the_work.md`.

### Hooks

- `senior-check-after.sh` reads `last_assistant_message` from the Stop
  payload and blocks a final answer that hands back undone work. It runs
  on push turns too, blocks twice at most per turn, and ignores the
  phrases inside code spans and quotes.
- The self-audit skips a turn that ran no command and made no edit. It
  needs a marker from a tool hook first, so the starter (two hooks, no
  tool hooks) still checks every turn. `SENIOR_MODE_AFTER_ALWAYS=1`
  turns the skip off.
- Fixed: a push made after the self-audit block left
  `claude-push-done-<session>` behind, and the next turn's self-audit
  was skipped. The before-hook and every allow now clear it.
- `session-registry.sh unregister` (SessionEnd) removes the session's
  state files from the temp dir.
- `exit-code-mask-guard.sh` read any `|` after the watcher as a pipe on
  it. It denied the redirect recipe when the next command had a pipe
  (`gh run view --jq '.jobs[] | .name'`), and it denied `|| echo red`. It
  now looks at the watcher's own segment only.
- The stop hook marks line breaks with a printable token. The first
  push used the `\001` byte, which bash 3.2 on macOS drops from a regex,
  and the "Open items" heading case failed there.
- `senior-check-before.sh` and `ultracode-advisor.sh` stay silent on a
  background-task notification. Claude Code runs prompt hooks for those,
  and both were treating the notification as a prompt.
- `ultracode-advisor.sh` matched substrings. It fired on "session",
  "author", "className" (it contains "ssn"), "git checkout", "open
  tests" and "dependency injection". The patterns have boundaries now.
- The advisor used to tell the agent to prefer a multi-agent workflow.
  Claude Code only runs one when you ask. It now names the reviewer to
  run and says a workflow is your call.
- `senior-verify-counterfactual.sh` judges the `Without senior mode`
  line of the `[AFTER-AUDIT]` block. The `[WITHOUT HOOKS]` section is
  gone. Its default judge model is `claude-haiku-5-5`.
- The Gemini shims pass `prompt_response` to the Stop hook as
  `last_assistant_message`.

### Installer

- `install.sh --upgrade`. Re-running the installer over a v5 install
  kept all 39 files that had changed, the stop hook included, so nobody
  got a fix by re-running it. `--upgrade` replaces the kit's own code
  (hooks, shims, procedures, generated skills, commands and workflows),
  saves each old copy under `.senior-mode/backup/<stamp>/`, and leaves
  your `AGENTS.md`, doctrine docs, rules, reviewers, memory and agent
  settings on the old keep-and-merge rule.

### Claude Code

- `full-audit.mjs` is now `full-audit.js`. Claude Code 2.1.330 loads a
  saved workflow only from a `.js` file and skips `.mjs`, so the workflow
  couldn't be run by name. The installer never deletes, so it prints a
  note when it finds the old file.
- Removed `adapters/claude/settings.json`. Nothing read it, and its hook
  paths were the v4 ones.
- `PROMPTING.md`, `prompt-auditor` and `/audit-prompt`: assistant
  prefill, a fixed `budget_tokens` and the sampling parameters now
  return a 400 on newer models, so the rubric flags them. Structured
  outputs join the forced tool call as the way to get a typed object.
  Model tiers are named without version numbers.
- `SETUP.md` said Gemini has no block-and-re-prompt for the AFTER
  check. It has had one since the AfterAgent deny landed.

### Harness

- 144 cases (146 with bun), up from 98. The 46 new ones cover the
  undone-work check, the 3-block cap, quiet turns, the push flag, the
  before-hook's notification handling, the session-end cleanup, the
  advisor's boundaries and reviewer routing, the Gemini mapping, the
  installer's upgrade mode, the pipe guard's segment rule, and a check
  that the starter's two hooks are byte-identical to core's. Run against the v5 hooks, 20 of them fail.
- The harness now runs in its own temp dir. The hooks keep per-session
  state files there, and a marker left by one run changed what the next
  run saw.

## v5 (2026-08-24): every agent, one core, a stack picker

The headline: the kit is no longer wired to one agent. One source of
truth in the repo (`.senior-mode/`), an `AGENTS.md` every agent reads,
and a thin generated adapter per agent. Plus a stack registry with
detection and a picker, and six new stack profiles.

### Universal core

- `core/` is the source of truth: `hooks/`, `rules/`, `reviewers/`,
  `commands/`, `memory/`. Installed as `<repo>/.senior-mode/`.
- `AGENTS.md` is the universal entry point (posture, the BEFORE-AUDIT
  block, rules-by-path table, procedures, reviewers, stack, agent wiring).
  `CLAUDE.md` is now a shim: `@AGENTS.md` plus Claude Code specifics.
  Kept under ~8 KB because Codex caps combined project docs at 32 KiB.
- The hooks resolve the repo root from `SENIOR_MODE_PROJECT_DIR`,
  `CLAUDE_PROJECT_DIR` (Cursor and Gemini export it as an alias),
  `CURSOR_PROJECT_DIR`, `GEMINI_PROJECT_DIR`, then cwd. `SENIOR_MODE_*`
  variants of `CLAUDE_FORMAT_CMD`, `CLAUDE_ALLOW_SHARED_GIT`, and
  `CLAUDE_SESSION_TTL_MIN` are honored alongside the old names.
- Procedures are also emitted as Agent Skills in `.agents/skills/<name>/SKILL.md`,
  the location Cursor, Codex, Gemini, Copilot, OpenCode, Amp, Zed, Warp,
  Junie, Factory, Augment, and Devin CLI read.

### Adapters (`adapters/`)

- The Claude Code hook JSON contract is the canonical one and is spoken
  natively by Codex CLI, Copilot (CLI, cloud, VS Code), Factory Droid,
  Devin CLI, Augment, and Junie. Adapters for those only choose the file
  name and repo-root expression: `.claude/settings.json`,
  `.codex/hooks.json`, `.github/hooks/senior-mode.json`,
  `.factory/hooks.json`, `.devin/hooks.v1.json`, `.augment/settings.json`.
- Cursor (`.cursor/hooks.json`) and Gemini (`.gemini/settings.json`) get a
  shim (`adapters/shims/`) that translates payloads both ways. OpenCode
  gets a plugin (`.opencode/plugins/senior-mode.ts`) that runs the same
  scripts and denies by throwing.
- Rules, reviewers, and commands are transformed per agent: `.cursor/rules/*.mdc`
  (globs), `.github/instructions/*.instructions.md` (applyTo),
  `.devin/rules`, `.augment/rules`; `.codex/agents/*.toml`,
  `.cursor/agents`, `.github/agents/*.agent.md`, `.gemini/agents`,
  `.opencode/agents`, `.factory/droids`; `.gemini/commands/*.toml`,
  `.opencode/commands`, `.factory/commands`, `.augment/commands`.
- `adapters/README.md` is the capability matrix, including what each
  agent cannot do and how the kit degrades there.

### Stacks (`stacks/`)

- `stacks/detect.sh` scores every profile's `detect.txt` signals against
  a repo and prints ranked evidence with a verdict (DETECTED, CANDIDATES,
  UNKNOWN, GREENFIELD). `--list` prints the picker cards from each
  profile's `profile.json`. `--json` for the installer.
- `profile.json` per profile: the card, the sanctioned commands, layout
  globs, LOC budgets, migration tool, which reviewers apply, how the app
  verifier boots the app. Agents read it instead of guessing commands.
- Six new profiles: `node-api-postgres`, `python-fastapi-postgres`,
  `django-postgres`, `rails-postgres`, `go-service`, `rust-service`, each
  with detect signals, a card, a README, a concrete `WORKFLOW.md`, and
  four path-scoped rules with real helper names.

### Installer

- `install.sh --agent <list|auto|all|none> --stack <name|auto|none>`.
  `auto` detects agents from config dirs in the repo and CLIs on PATH,
  and installs a stack profile only on a confident detection. Same
  non-clobbering rules as before (`<file>.senior-mode` beside conflicts).
- The kickoff prompt is agent-neutral: step 0 confirms the agent's wiring
  is live, step 1 confirms or picks the stack from the detector's output.

### Harness

- New cases: the detector's four verdicts and the picker, both shims in
  both directions, a real install of core + two adapters into a scratch
  repo, the installed hook denying from its new location, generated JSON
  parsing (when Node is present). CI runs it on Linux, macOS, Windows.

### Renamed or moved

- `.claude/hooks/` -> `core/hooks/` (installed at `.senior-mode/hooks/`);
  `.claude/rules/` -> `core/rules/`; `.claude/agents/` -> `core/reviewers/`;
  `.claude/commands/` -> `core/commands/`; `memory/` -> `core/memory/`;
  `.claude/workflows/` -> `adapters/claude/workflows/`.
- `install.sh --profile` -> `--stack` (the old flag still works).
- `user-claude-md-template.md` removed: `starter/` (`--agent`) is the global setup now, for every agent.

## v4.1 (2026-08-24): renamed to senior-mode

The kit was called claude-kit. It is not Claude-specific in spirit (the
doctrine, prompt standard, and memory bundle apply to any coding agent;
the hook wiring is Claude Code's today), so the name changed. Mechanical
renames, in case you installed the old name:

- Env vars: `CLAUDE_KIT_MAINLINE` -> `SENIOR_MODE_MAINLINE`,
  `CLAUDE_KIT_JUDGE_MODEL` -> `SENIOR_MODE_JUDGE_MODEL`.
- Installer merge suffix: `<file>.kit-new` -> `<file>.senior-mode`.
- Staging dirs: `.claude-kit-memory-staging/` ->
  `.senior-mode-memory-staging/`, `claude-kit-qa/` -> `senior-mode-qa/`.
- New: `starter/`, the 5-minute global install (two hooks, the doctrine,
  the prompt guide, `/review`), and `docs/`, the README GIFs and their
  generator.

## v4 (2026-08-24): universal edition, rebuilt on Claude Fable 5

The headline: the kit is now stack-neutral with an optional recommended
profile, and safe to install into a project that is already set up.

### Structure

- **Stack profiles.** Everything opinionated about Next.js, Vercel,
  Postgres, Drizzle, and Playwright moved out of the core into
  `stacks/nextjs-vercel-postgres/` (rules, `/stage`, `/qa-sweep`, the
  concrete `WORKFLOW.md`, `QA-SWEEP.md`, the QA pack). The core is
  language- and platform-agnostic. `STACK.md` states the
  recommendation and an adapt-to-yours matrix for Python, Rails, Go,
  Rust, and other JS stacks.
- **`install.sh`.** A non-clobbering installer: never overwrites an
  existing file (writes `<file>.senior-mode` beside it), stages memory,
  optional `--profile`, `--dry-run`, `--force`. Warns on a `.gitignore`
  that excludes `.claude/` and on an `AGENTS.md` without an import.
- **Kickoff rewritten** for existing projects: step 0 detects the stack
  from the manifests and only recommends a profile on greenfield; a
  merge step for `.senior-mode` files (settings hooks and permissions,
  CLAUDE.md, docs); a step that scopes rules with `paths:`.
- **Core rules** are now five stack-neutral files (`api-boundary`,
  `data-layer`, `ui`, `services`, `scripts`) with `<!-- SETUP -->`
  comments showing the `paths:` frontmatter to add.
- `/rls-audit` renamed `/tenant-audit` (the concept is not Postgres-
  specific).

### Aligned with current Claude Code

- Rules use the real `paths:` frontmatter key (a YAML list). A `globs:`
  key is not recognized and such rules load unconditionally.
- `SessionEnd` hook: the session registry now unregisters on exit
  instead of waiting for the TTL.
- `Stop` payload's `last_assistant_message` is used by the optional
  counterfactual verifier (transcript walk kept as fallback).
- Documented why the git gates self-filter instead of using the hook
  `if` field (prefix match; `cd x && git push` would evade it).
- Commands documented as skills (`.claude/commands/` and
  `.claude/skills/` are one mechanism); `/learn` writes procedures as
  skills; PROMPT-STANDARD has a "where an instruction should live"
  table.
- Subagent frontmatter options documented (`model: fable`, `effort`,
  `isolation: worktree`, `memory`), and agents hot-reload.
- `<!-- SETUP -->` HTML comments replace `> SETUP:` blockquotes in
  CLAUDE.md, rules, and doctrine docs: Claude Code strips them from
  context, so a note left in place is free.
- PROMPT-STANDARD: plan mode, `/rewind`, `/branch`, `/fork`,
  `/context`, `/effort`, `/fast`, `/verify`, `/batch`, `/loop`
  self-pacing, `/schedule` routines, `fork` subagents, worktree
  isolation.
- PROMPTING: Claude 5 model tiers with pinned IDs, adaptive thinking /
  effort over token budgets, tool-runner and managed-agent runtimes,
  compaction and the memory tool, Files API, fingerprint-gated evals,
  progressive disclosure for domain knowledge, "give the model a test,
  not a fact".
- `full-audit.mjs`: `REVIEWER` is unset by default (the default
  workflow subagent always exists; a plugin agent may not), verifiers
  and synthesis run at high effort, a `supply-chain` dimension added.

### Hooks (all covered by the harness, 47 cases)

- `pre-push-checklist.sh` and `pre-commit-audit.sh` validate the repo
  the command runs FROM, not `CLAUDE_PROJECT_DIR`. From a worktree the
  old behavior read the main checkout's HEAD, which both blocked
  compliant worktree commits and would have passed a non-compliant one.
- `session-registry.sh`: fork-free (pure bash) for Windows Git Bash
  performance, `unregister` mode, mainline auto-detection from
  `origin/HEAD` (`SENIOR_MODE_MAINLINE` override), lineage alert when
  HEAD shares no ancestor with the mainline, tmp-file pruning.
- `exit-code-mask-guard.sh` (new): denies piping a CI watcher through
  `tail`/`head`/`grep`, which made red runs report exit 0 five times in
  two months on one project.
- `ultracode-advisor.sh`: edits under `.claude/` no longer trip the
  auth signal (`session-registry.sh` contains "session"); path signals
  are segment-anchored; accepts both `prompt` and `user_input` payload
  keys.
- `pre-commit-audit.sh`: TODO/FIXME gate is language-agnostic (`//`,
  `#`, `--`, `/*`, `<!--`); exception comment window is the first 20
  lines (matches the sweeper and `/loc-budget`); more source
  extensions; `bin/` exempt from the print-debug check.
- `post-edit-format.sh`: auto-detects biome, prettier, ruff, black,
  gofmt, rustfmt, and deno fmt, preferring project-local binaries.
- `senior-check-before.sh` adds evidence-before-code and never-cite-an-
  unread-source; `senior-check-after.sh` adds "what would RED have
  looked like".
- `ship-policy.sh` emits proper hook JSON and stack-neutral wording.
- `test-checklist.sh`: 47 cases including the worktree push case, a
  language-agnostic TODO matrix, unregister, the mask guard, the
  advisor's `.claude/` exclusion, biome autodetect, and an
  `install.sh` dry-run + real-run smoke test; exits non-zero on failure.

### Doctrine

- ENGINEERING-PRINCIPLES section 19, "Verification craft (how a review
  lies to itself)": detectors that cannot fail, tests no runner imports,
  piped exit codes, empty-vs-crashed, exclude the observer, a guard is
  not immutability, widening a set misses its consumers, a count in a
  commit message is a claim, a fix can be right while its reason is
  false, absence claims are scoped, copy that lists a sample, unloaded
  looks absent, a green suite is not a look. Plus "never write from a
  GET", "never inherit the whole env into a child", and "confirm a test
  is reachable" in the never/always lists.
- WORKFLOW: "Two verification models" (local-heavy vs remote-heavy) so
  `/go`, `/iterate`, and the app-verifier have a defined behavior on
  teams where CI is the only heavy oracle; migration runner properties
  (ancestry check, advisory lock, transactional tracking rows); "CI
  green is not deployed".
- Agents: migration-reviewer gained the journal-watermark, raw-insert,
  and role-ownership checks; money-path-reviewer gained guard-is-not-
  immutability and silent non-writes; tenant-isolation-reviewer gained
  raw-SQL casts, GET-that-writes, widened sets, child-process env;
  prompt-auditor gained model-ID hygiene and purity + evals;
  conventions-sweeper gained partial-enumeration copy and orphaned
  tests; app-verifier gained the two detector rules and the load-gap
  check.
- Memory bundle: `feedback_evidence_before_code` (the visible
  BEFORE-AUDIT block) and `feedback_never_cite_an_unread_source`.
  Index notes the 200-line / 25KB load limit.

### Leak scrub

Every domain-specific term from the source project was replaced
(tenant terminology throughout, generic money-chain examples, generic
sensitive-data examples, no product names, hosts, ids, or people).

## v3 (2026-07-12): parallel sessions and the inner loop

Parallel-session pack (`session-registry.sh`, `session-tree-guard.sh`,
`/worktree`), fork-free harness, `post-edit-format.sh`,
`permissions.allow`, `/go`, `/techdebt`, `/learn`, `app-verifier`
agent, and the delegate-don't-pair / context-hygiene doctrine.

## v2 (2026-06-10): review subagents and verification loops

Five review subagents wired into `/pre-push`, self-filtering git gates,
modernized PROMPTING.md, verification-loop doctrine and `/iterate`, the
QA pack and ship loop, the Stop-hook loop backstop.
