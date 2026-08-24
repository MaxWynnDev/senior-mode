---
description: Isolate this session in its own git worktree (own branch off the mainline) so concurrent sessions never tangle the shared checkout. List or tear down with `list` / `done`.
argument-hint: [slug | list | done]
---

GOAL: move THIS agent session out of the shared checkout and into its
own git worktree so it can edit, commit, and push without tangling the
tree another live session is using. Argument: `$ARGUMENTS` (empty or a
short feature slug, `list`, or `done`).

Background: the session hooks in this kit register a heartbeat
(`.senior-mode/hooks/session-registry.sh`) and a tangle guard
(`.senior-mode/hooks/session-tree-guard.sh`) that BLOCKS commit and push
from a shared checkout for any session that is not the incumbent
(earliest). The fix is to give the later session its own worktree: it
shares the repo object store but has its own working tree, so two
sessions can never mix edits. Worktrees are git-isolation only, no
`node_modules` / build artifacts unless you install them there.

Mainline: run `git symbolic-ref --short refs/remotes/origin/HEAD` and
use what it prints (`origin/main`, `origin/master`, `origin/trunk`).
Call it `<mainline>` below. If it prints nothing, `git remote set-head
origin -a` once, or assume `main`.

## If `$ARGUMENTS` is `list`

1. `bash .senior-mode/hooks/session-registry.sh list`: the table of live
   sessions (sid, branch, checkout vs worktree, age, toplevel).
2. `git worktree list` next to it.
3. State plainly whether this session is the incumbent in its checkout
   or should isolate.

## If `$ARGUMENTS` is `done`

1. Confirm this worktree's work is shipped (its commits are on
   `origin/<mainline>`) or is being deliberately abandoned. If there
   are unpushed commits, STOP and surface them. Never remove a worktree
   with unshipped work without the user's explicit go-ahead.
2. Note the worktree path and branch (`git rev-parse --show-toplevel`,
   `git branch --show-current`).
3. Return to the main checkout FIRST (`cd "$CLAUDE_PROJECT_DIR"`, or
   the `ExitWorktree` tool where available), then
   `git worktree remove <path>` (add `--force` only if step 1 cleared
   it). Removing the directory the shell is standing in strands the
   session.
4. Delete the isolation branch: `git branch -D <branch>` once it is
   merged to the mainline or abandoned.
5. `git worktree prune` and confirm `git worktree list` is clean.

## Otherwise (create + enter a worktree)

1. Fetch first so the worktree starts from the current mainline:
   `git fetch origin`.
2. Branch name `wt/<slug>` where `<slug>` is `$ARGUMENTS` (sanitized to
   `[a-z0-9-]`) if given, else a short tag derived from the work in
   hand. Do not reuse a branch already checked out in another worktree
   (git refuses that by design).
3. Worktree path is a SIBLING of the repo, never nested inside it:
   `<parent-of-CLAUDE_PROJECT_DIR>/<repo-name>-worktrees/<slug>`.
   Nesting a worktree inside the repo pollutes `git status`, the rules
   loader, and every recursive search.
4. Create it off the fresh mainline:
   `git worktree add -b wt/<slug> "<path>" origin/<mainline>`.
5. Enter it: prefer the native `EnterWorktree` tool to relocate this
   session to `<path>`. If that tool is unavailable, `cd "<path>"` and
   do all further git work from there. After entering, the heartbeat
   banner recognizes you as isolated; the tangle guard no longer
   blocks you.
6. Tell the user, in this order:
   - the worktree path and branch;
   - that it is git-isolation only (no dependencies installed): run the
     app and tests from the main checkout, or install deps in the
     worktree once first if you must run them here;
   - how to ship from here: `git fetch origin`,
     `git rebase origin/<mainline>`, resolve any conflicts, then commit
     with the `Senior-Checklist:` trailer and
     `git push origin HEAD:<mainline>` (or open a PR if the project
     uses them). If the push is rejected as non-fast-forward, another
     session shipped first: `git fetch origin && git rebase
     origin/<mainline>` and push again;
   - that `/worktree done` removes it when finished.

STOP CONDITION: the session is isolated (or listed / torn down) and the
user has the shipping instructions. `wt/<slug>` is a short-lived
isolation branch whose commits land on the mainline by rebase + push
(or by the project's PR flow); it is not a long-lived feature branch.
