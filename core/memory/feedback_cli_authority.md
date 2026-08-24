---
name: feedback-cli-authority
description: Authorized to run CLIs (migrations, env changes, deploy) directly without asking, once confirmed for a project
metadata:
  type: feedback
---

The user authorizes running operational CLIs directly (prod migrations,
env var changes, deploy commands, platform CLI) without asking for
permission each time, PROVIDED the action itself is sound and verified.

**CONFIRM PER PROJECT.** This is a standing preference for the user's own
projects. On a new repo, confirm once that the same authority applies
before acting on it, especially for anything irreversible.

**How to apply:** the authority covers running the command; it does not
relax the senior bar on whether the command is the right thing to do.
For irreversible actions (a prod migration, a force push, a destructive
script), still verify the diagnosis and the blast radius first
([[feedback-senior-engineer-default]]), then execute without a separate
permission round-trip.
