# Security

## What this software does, plainly

senior-mode installs shell scripts that your coding agent executes
automatically: on every prompt, on every tool call, and at the end of every
turn. Installing it means agreeing to run this code with your user's
privileges, in your repository, without a prompt each time. That is the
same trust you extend to a git hook or a `Makefile`, and it deserves the
same scrutiny.

Read the scripts before you install. They are in `core/hooks/`, they are
bash, and the longest one is a few hundred lines.

## The threat model

What the hooks do:

- read the hook payload on stdin (a command string, a file path, a prompt)
- run `git` read commands against the repository
- write heartbeat files under `$(git --git-common-dir)/agent-sessions/`
  and sentinel files in the system temp directory
- run a formatter you already have installed, on a file the agent just
  edited
- print JSON to stdout

What they do not do: make network requests, read your environment beyond
the few documented `SENIOR_MODE_*` variables, send anything anywhere, or
modify files outside the two locations above. The one exception is opt-in
and off by default: `senior-verify-counterfactual.sh` calls the Anthropic
API and needs `ANTHROPIC_API_KEY`. It is not wired by any adapter unless
you wire it.

## The failure mode you should actually worry about

Hooks fail open by design. If a hook crashes, times out, or receives
something it cannot parse, the action is allowed. This is deliberate: a
guardrail that blocks your work when it breaks gets uninstalled, and an
uninstalled guardrail guards nothing.

The consequence is that **these are guardrails, not a security boundary**.
The commit gate, the push gate, and the pipe guard stop an agent that is
being careless. None of them stop an agent, or a person, that is trying to
get around them, and none of them are a sandbox. If you need to contain
what an agent can do, use your agent's own permission and sandbox settings.
senior-mode does not replace them.

## Reporting a vulnerability

Open a [security advisory](https://github.com/MaxWynnDev/senior-mode/security/advisories/new)
rather than a public issue, and give me a week before disclosing.

Things I consider vulnerabilities:

- a hook payload that causes a script to execute attacker-controlled input
  (the guards receive command strings from the agent; they must only ever
  match against them, never evaluate them)
- a path in the installer that writes outside the target directory
- a generated config that runs something other than the kit's own scripts
- an adapter that leaks environment contents into a file or into a prompt

Things I do not: a hook failing open (that is the design), the push gate
being bypassable by someone with a shell (of course it is), or a guard not
catching a command it was never written to catch. Those are feature
requests, and they belong in issues where everyone can see them.
