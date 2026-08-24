# START HERE

You were handed `senior-mode`: a portable engineering setup for coding
agents. Installing it into a repo gives whichever agent you use the same
senior-engineer self-checks, commit and push gates, parallel-session
tangle protection, auto-formatting, procedures, six reviewers, prompt
standards, a stack profile picked from evidence, and a memory of how you
like to work. It works on a brand-new repo and on a project that is
already set up, on any stack, with Claude Code, Codex CLI, Cursor,
Gemini CLI, GitHub Copilot, OpenCode, Factory Droid, Devin CLI, Augment,
and (doctrine only) anything else that reads `AGENTS.md`.

## What you need first

- One or more of the agents above, installed.
- **bash** on your PATH. macOS and Linux have it. On **Windows**, install
  Git for Windows so "Git Bash" is available (the hooks run via `bash`).
- **git**.

## Install (3 steps)

1. **Run the installer** from the cloned kit folder. It writes the
   universal core to `.senior-mode/`, the entry point to `AGENTS.md`, the
   doctrine docs to the root, the procedures to `.agents/skills/`, and
   the wiring for every agent it finds (a config dir in your repo, or a
   CLI on your PATH). It never overwrites a file you already have; the
   new version goes beside it as `<file>.senior-mode`.

   ```bash
   bash install.sh --dry-run /path/to/your-repo     # see what would happen
   bash install.sh /path/to/your-repo               # agents: auto-detected; stack: detected from manifests
   ```

   Choose explicitly when you want to:

   ```bash
   bash install.sh --agent claude,codex --stack none /path/to/your-repo
   bash install.sh --agent all --stack python-fastapi-postgres /path/to/your-repo
   bash install.sh --list-stacks                    # the stack picker
   ```

   Windows: run the same commands from Git Bash. `--agent all` is slow
   there (nine adapters, many small processes); pick the agents you use.

2. **Open your agent in the repo** and paste the entire contents of
   `.senior-mode/KICKOFF-PROMPT.md`. It confirms the wiring is live,
   confirms or picks the stack with the evidence, merges any
   `.senior-mode` files with you, interviews you to fill in the project
   placeholders, deletes the reviewers your project does not need, and
   runs the harness.

3. **Start working.** The hooks fire automatically from then on. Editing
   the source in `.senior-mode/` and re-running `install.sh` regenerates
   every agent's wiring.

## Read these next

- `README.md`: what every file in the kit is, and how one kit fits every
  agent.
- `SETUP.md`: the detailed install, what each hook, reviewer, and
  procedure does, per-agent notes, and how to tune them.
- `adapters/README.md`: the capability matrix (what each agent can
  enforce, what it can only be asked).
- `stacks/README.md`: how the stack is detected and picked, and how to
  write a profile.

## Heads up

- The doctrine docs and `AGENTS.md` ship as **templates** with
  `<PROJECT>` / `<...>` placeholders and `SETUP:` notes. The kickoff walks
  you through the important ones; the rest you fill in as you go. Keep
  `AGENTS.md` short: several agents cap it, and every line costs context
  on every turn.
- Commit `.senior-mode/`, `AGENTS.md`, `.agents/`, and your agents'
  generated dirs. Teammates only get this setup if it is in the repo.
  The installer warns when `.gitignore` excludes them.
- On Windows, if the hooks do nothing, it is almost always because
  `bash` is not on PATH.
- Running several agent sessions at once (even different agents) in one
  checkout is supported: the session registry steers later sessions to a
  worktree and blocks their commits until they isolate. If a block fires
  on a session that is actually dead, prefix the one command with
  `SENIOR_MODE_ALLOW_SHARED_GIT=1`.

## One commit convention the push gate enforces

Once installed, `git push` is blocked unless your HEAD commit ends with a
trailer like:

```
Senior-Checklist: ambiguity=pass summary=pass concurrency=n/a regression=pass blast=green
```

This is intentional. It forces a quick senior self-check before the
irreversible action. Grades: `pass | miss | n/a` (`blast` also takes
`green | red`). All five keys required. See
`.senior-mode/hooks/pre-push-checklist.sh` for the full spec, or remove
that hook from your agent's wiring if you do not want it.
