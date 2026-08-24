---
name: feedback-deploy-preference
description: Default deploy/branching preference; confirm and adjust per project
metadata:
  type: feedback
---

The user's default preference on their own projects is to commit and push
straight to the deploy branch, with safety living in CI, the deploy gate,
and rollback rather than in pull requests or branch protection. No
feature branches, no PRs, unless the project specifically needs them.

**CONFIRM PER PROJECT.** Branching and deploy models vary a lot between
teams and repos. On a new project, read `WORKFLOW.md` and confirm the
model before acting. If the project uses PRs and protected branches,
follow that instead and update this memory (or delete it) for that
project.

**How to apply:** once the model is confirmed, do not propose adding PRs,
branch protection, a staging environment, or feature flags unless the
user asks. If the model is the push-to-deploy-branch one, the
`pre-push-checklist.sh` Senior-Checklist trailer is the gate that makes
the irreversible push deliberate.
