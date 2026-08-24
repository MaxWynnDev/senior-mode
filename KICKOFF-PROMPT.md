# Kickoff Prompt

Paste everything below the line into a fresh session of your coding agent
(Claude Code, Codex, Cursor, Gemini CLI, Copilot, OpenCode, or any agent
that reads `AGENTS.md`) opened in your project's root, AFTER you have run
`install.sh`. The agent finishes the setup.

---

You are finishing the installation of "senior-mode", a portable,
agent-neutral engineering setup, into this repository. The installer has
already written `.senior-mode/` (the source of truth: hooks, rules,
reviewers, commands, memory, stack profiles), `AGENTS.md` at the root
(the universal entry point; `CLAUDE.md` imports it for Claude Code), the
doctrine docs, `.agents/skills/`, and the wiring for the agents it
detected. Files that already existed and differed were left alone; the
new version sits beside them as `<file>.senior-mode`.

GOAL: (1) confirm which agent you are and that your wiring is live,
(2) confirm or pick the stack from evidence, (3) merge every
`.senior-mode` file with its existing counterpart, (4) interview me to
fill the placeholders in `AGENTS.md` (and `CLAUDE.md` if present),
(5) install the memory bundle where your agent keeps memory, or confirm
it will be read from `.senior-mode/memory/`, (6) scope the rules to my
file layout, (7) delete the reviewers whose domain this repo lacks,
(8) run the harness and report.

CONSTRAINT: do not run any prod commands (migrations, deploys, env
changes, `git push`). Do not install dependencies, start servers, or run
test suites; the only scripts you run are `.senior-mode/stacks/detect.sh`
and `.senior-mode/hooks/test-checklist.sh`. This session is read-only
except for (a) merging `.senior-mode` files, (b) editing `AGENTS.md`,
`CLAUDE.md`, the rules' path globs, and your agent's generated wiring,
(c) moving the memory bundle, (d) deleting inapplicable reviewers. Do
not commit anything. Do not invent project facts: ask me for anything
you cannot read from the repo. Never cite a file you have not opened.

EVIDENCE: `.senior-mode/SETUP.md` explains every piece and where each
agent's wiring lives. `.senior-mode/stacks/README.md` explains the stack
picker. Placeholders are marked `<PROJECT>`, `<...>`, and `SETUP:` notes
(some inside HTML comments; read the files with your file tool, not from
loaded context, to see them).

OUTPUT SHAPE: do each numbered step in order. After each step, print one
short line confirming what you did. End with a "ready to work" summary.

STOP CONDITION: when the wiring for my agent is confirmed live, the stack
is confirmed or picked and recorded in `AGENTS.md`, every `.senior-mode`
file is merged and removed, the placeholders I gave you facts for are
filled, the memory bundle is installed or its location confirmed, the
harness is green, and you have printed the summary. Then stop and wait
for my first real task.

## Steps

### 0. Which agent are you, and is your wiring live?

Say which agent you are. Then check the matching wiring exists and read
it (one file):

| Agent | Wiring | Live check |
|---|---|---|
| Claude Code | `.claude/settings.json` | you received `[SENIOR CHECK \| BEFORE]` with this prompt |
| Codex CLI | `.codex/hooks.json` | run `/hooks` and approve the senior-mode hooks; the next prompt carries the check |
| Cursor | `.cursor/hooks.json` | the session started with the checklist as additional context |
| Gemini CLI | `.gemini/settings.json` | `/hooks list` shows the senior-mode hooks |
| Copilot | `.github/hooks/senior-mode.json` | the check appears on the next prompt (CLI) |
| OpenCode | `.opencode/plugins/senior-mode.ts` | the system prompt carries the checklist |
| Factory / Devin / Augment | `.factory/hooks.json`, `.devin/hooks.v1.json`, `.augment/settings.json` | next prompt |
| anything else | none (AGENTS.md only) | say so: the gates are instructions for you, not hooks |

If your agent's wiring is missing, tell me the command to add it:
`bash <kit>/install.sh --agent <name> .` Print one line with the result.

### 1. Detect the stack and confirm or pick a profile

Run `bash .senior-mode/stacks/detect.sh .` and paste the verdict line.

- **DETECTED**: the profile is installed at
  `.senior-mode/stacks/<name>/`. Read its `profile.json` and confirm with
  me in five lines: language and framework, data and ORM, migration
  runner, deploy target and CI, package manager. Those commands are the
  sanctioned ones from now on.
- **CANDIDATES**: show the evidence and ask me which (or none).
- **UNKNOWN**: the repo is on a stack with no profile. Read the manifests
  yourself, state the five lines, and tell me which kit pieces will be
  adapted using the table in `.senior-mode/STACK.md`.
- **GREENFIELD**: run `bash .senior-mode/stacks/detect.sh --list`, walk
  me through the cards, recommend one with the reasons from its
  `README.md` (you can read them at `<kit>/stacks/<name>/README.md`
  or ask me for the kit path), and wait for my pick. Then tell me the
  install command: `bash <kit>/install.sh --stack <name> .` and stop
  until I have run it.

Record the decision in the `## Stack` section of `AGENTS.md`. Print one
line.

### 2. Merge the `.senior-mode` files

List every `*.senior-mode` file (`git ls-files --others --ignored
--exclude-standard` plus a plain `find . -name '*.senior-mode' -not -path
'./node_modules/*'`). For each:

- `AGENTS.md.senior-mode`: keep my existing `AGENTS.md` as the base and
  merge in the senior-mode sections it lacks (the posture, the rules
  table, procedures, reviewers, stack, agent wiring). Do not duplicate
  anything I already say.
- `CLAUDE.md.senior-mode`: keep mine as the base; make sure the first
  line is `@AGENTS.md` and fold in the Claude Code specifics section.
- `.claude/settings.json.senior-mode` (or the equivalent for your agent):
  merge the `hooks` (and for Claude Code the `permissions.allow`) into my
  existing file. Show me the merged JSON before writing it.
- Doctrine docs (`ENGINEERING-PRINCIPLES.md`, `PROMPT-STANDARD.md`,
  `PROMPTING.md`, `WORKFLOW.md`): if my existing file is a real doc,
  merge the kit's sections it lacks; if it is a stub, replace it.
- Anything under `.senior-mode/`: the kit version wins unless I say
  otherwise (it is generated content).

Delete each `.senior-mode` file after merging. Print the list.

### 3. Fill the placeholders

Read `AGENTS.md`. For each `<PROJECT>` / `<...>` placeholder and each
`SETUP:` note, ask me one question at a time, in the order they appear:
product name and brand spelling, the stack lines (if not already filled
in step 1), the sanctioned commands (from `profile.json` when there is a
profile), the deploy model (`WORKFLOW.md` ships two: push-to-mainline
behind a CI gate, or PRs with a protected branch; delete the other),
what this repo deliberately does NOT have, the date helpers if any, and
the copy-style preference. Write the answers in. Repeat for `CLAUDE.md`
if present. Delete the `SETUP:` comments you have acted on. Print the
count of placeholders filled and any left open.

### 4. Memory

The bundle is at `.senior-mode/memory/` (an index plus working-style
preferences).

- Claude Code: move the files into this repo's auto-memory directory
  (`~/.claude/projects/<project>/memory/`; `ls "$HOME/.claude/projects/"`
  and pick the entry for this repo; create `memory/` if needed). Do not
  overwrite files already there; if a `MEMORY.md` exists, append the
  kit's index lines. Print the counts moved and skipped.
- Every other agent: there is no file-based memory to move to. Confirm
  that `AGENTS.md` points at `.senior-mode/memory/MEMORY.md` and read the
  index now. Print one line.

Flag the two preferences marked CONFIRM PER PROJECT
(`feedback_cli_authority`, `feedback_deploy_preference`) and ask me
whether they apply here.

### 5. Scope the rules to my layout

For each rule your agent has wired (`.claude/rules/*.md` `paths:`,
`.cursor/rules/*.mdc` `globs:`, `.github/instructions/*.instructions.md`
`applyTo:`, or the "Rules by path" table in `AGENTS.md` for agents with
no native scoping), replace the suggested globs with this repo's real
directories. Read the tree first; do not guess. Print the mapping.

### 6. Delete inapplicable reviewers

Read `.senior-mode/reviewers/`. Delete, in `.senior-mode/reviewers/` and
in your agent's generated copy, any reviewer whose domain this repo
lacks: `money-path-reviewer` if no money moves, `tenant-isolation-reviewer`
if single-tenant, `prompt-auditor` if there are no LLM call sites,
`migration-reviewer` if there is no database. Ask before deleting when
unsure. Print what stays.

### 7. Run the harness and report

Run `bash .senior-mode/hooks/test-checklist.sh` and paste the last line.
Then print the "ready to work" summary: agent, wiring file, stack and
profile, placeholders filled (count) and open (list), `.senior-mode`
files merged (list), memory location, reviewers kept, harness result.
Stop and wait for my first task.
