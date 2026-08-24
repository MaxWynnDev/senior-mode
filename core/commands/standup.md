---
description: Weekly "what shipped" digest. Commits, deploys, error-reporter hits, debt added
argument-hint: [days=7]
---

GOAL: generate a shipping digest for the last N days (default 7,
override with the first argument: `/standup 14`). Read-only report;
modify nothing.

## Procedure

Adapt platform commands to WORKFLOW.md; the reference stack's
invocation is shown in brackets.

1. **Commits on the mainline** since the window:
   `git log --since="<N> days ago" --pretty=format:"%h %ad %s" --date=short`

   If the repo ships fast (dozens of commits a week), do NOT enumerate.
   Group by conventional-commit prefix (feat, fix, refactor, docs,
   chore, perf, test, ci) and report:
   - Count per group
   - Top 3 most consequential commits per group (use judgment: a feat
     that introduces a new surface beats a feat that polishes an
     existing one; a fix touching money paths beats a fix touching CSS)
   - Any commit on a money path listed in full regardless of category.

2. **Production deploys** in the same window [reference stack:
   `vercel ls --prod`, then `vercel inspect <url> --logs 2>&1 | grep
   -oE "Commit: [a-f0-9]+" | head -1` for the SHA]. For each successful
   deploy, extract the source commit SHA. Canceled builds from a
   CI-gated deploy are normal; do not flag them. DO flag any mainline
   commit from step 1 with NO matching successful deploy.

3. **Error-reporter activity** in the window:
   - If no reporter token is set in the environment, print one line
     saying so and skip.
   - Otherwise: count of new issues, top 3 by event count with their
     release tag, and any issue whose release SHA matches a commit from
     step 1 (flag correlations clearly).

4. **Scheduled-job health**: any cron or scheduled job with no
   successful run in the window, if the project logs runs. One line if
   all healthy.

5. **Debt added this week**:
   - Files modified by the commits whose line count is now over 400
     (cross-reference the LOC budget). Show the LOC delta if the file
     already existed.
   - New TODO/FIXME lines added in the window with no date or owner
     (`git log -p --since=... -G 'TODO|FIXME'`).
   - Test files added in the window that no runner imports.

OUTPUT SHAPE: markdown suitable for pasting into a notes doc. Top
header `## Week of <start> to <end>` (ISO dates), then `## Shipped`,
`## Deploys`, `## Errors`, `## Scheduled jobs`, `## Debt added`. If
the Artifact tool is available and the user wants to share the digest,
offer to publish it.

STOP CONDITION: report printed. Anything alarming found along the way
(unshipped commit, correlated error spike, dead cron) is flagged in
place, not silently folded into prose.
