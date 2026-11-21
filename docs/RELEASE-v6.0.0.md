The answer ends with what got done.

I kept getting answers that ended with a list of what the agent didn't do.
v5 was asking for that list in five places. v6 takes the ask out, and the
stop hook now reads the final answer and sends it back when it hands you
work.

## Upgrade

```bash
git -C senior-mode pull
bash senior-mode/install.sh --upgrade --dry-run /path/to/your-repo   # what it would replace
bash senior-mode/install.sh --upgrade /path/to/your-repo
```

`--upgrade` is new. It replaces the kit's own hooks, shims and procedures
and saves each old copy under `.senior-mode/backup/`. It keeps your
`AGENTS.md`, doctrine docs, rules, reviewers and memory, and writes the new
version of each beside yours as `<file>.senior-mode`. Merge the "Before you
say done" section and the `[BEFORE-AUDIT]` block from
`AGENTS.md.senior-mode` by hand. A plain re-run doesn't upgrade anything.
It keeps every file that differs.

The starter installer never overwrites either. For Claude Code:

```bash
bash senior-mode/starter/install.sh
mv ~/.claude/hooks/senior-check-before.sh.starter ~/.claude/hooks/senior-check-before.sh
mv ~/.claude/hooks/senior-check-after.sh.starter  ~/.claude/hooks/senior-check-after.sh
```

Then merge `~/.claude/CLAUDE.md.starter` into your `CLAUDE.md`.

## What changed

The agent finishes the work in the turn. A decision that's yours comes as
one multiple-choice question. A step only you can take comes as exact
instructions. A failed check is reported as failed.

Non-trivial work closes with an `[AFTER-AUDIT]` block: what the turn
covered and how it was verified, and what the checks caught that a first
pass would have shipped without. "Nothing this turn" is a valid answer.

`senior-check-after.sh` reads `last_assistant_message` from the Stop
payload. A final answer with a "what I didn't do" list, an "I haven't
tested" or an "Open items" heading gets blocked with one instruction: do it
now. It blocks twice at most per turn, runs on push turns too, and ignores
those phrases inside code spans and quotes. Claude Code and Codex send the
field, the Gemini shim maps `prompt_response` to it, and an agent that
doesn't send it skips the check.

The self-audit now skips a turn that ran no command and made no edit, so a
question gets its answer in one round.

The advisor hook matched substrings and fired on "session", "author" and
"git checkout". It has word boundaries now. It also names the reviewer to
run and leaves a multi-agent workflow to you.

`full-audit.mjs` is `full-audit.js`. Claude Code only loads `.js`
workflows, so the old file couldn't be run by name.

The prompting rubric knows that newer models reject assistant prefill, a
fixed `budget_tokens` and the sampling parameters.

The harness has 141 cases, up from 98. `CHANGELOG.md` has the full list.
