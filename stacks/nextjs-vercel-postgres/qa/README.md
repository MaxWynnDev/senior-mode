# QA pack

Machine-finds-the-bugs-first infrastructure, extracted from a working
setup. Four pieces that layer together; install what fits your stack
(defaults assume Next.js App Router + Postgres-with-branching (e.g.
Neon) + Vercel; every piece degrades gracefully if you swap parts).

| Piece | File(s) | What it gives you |
|---|---|---|
| Page sweep spec | `pages-smoke.spec.template.ts` | A Playwright spec that renders EVERY static page of your app on every push (routes discovered from the filesystem, so new pages are covered automatically) and fails on 5xx, client crashes, error boundaries, or 500ing API calls. Put it in your gating CI job. Also sweeps deployed targets via a remote `BASE_URL`. |
| Nightly sweep | `qa-sweep.yml.template` | GitHub Actions workflow that runs the same sweep against your LIVE site nightly with a low-privilege test login, and uploads failure screenshots. |
| Staging on demand | `stage-up.mjs`, `stage-down.mjs`, `stage-shared.mjs` | One command: copy-on-write DB branch off prod + preview deploy wired to it + stable alias. Rehearse migrations against real-shaped data. Dry-run-by-default teardown. |
| QA sandbox | `QA-SANDBOX-SEED-CHECKLIST.md` | What to seed (synthetic tenant, member-role sweep login, fake counterparties that sink into a mailbox you control) so agents can exercise real integrations with zero customer risk. The seed code itself is too app-specific to template; the checklist is the contract. |
| Sweep launcher | `qa-codex-sweep.ps1` | Invokes codex (or any agent CLI) as the sweeper: exports QA creds to env (never the prompt), runs the QA-SWEEP.md brief, exits 0 on a CLEAN `qa-findings.md` verdict, 2 on findings, archives each run to `qa-findings-archive/`. Pass `-Headed` to open a visible browser window (PWHEADED=1) so you watch the agent work. The verify leg of `/ship`. |
| Pipeline dashboard | `dashboard/` | A dev-gated page that surfaces the whole pipeline (CI, nightly sweep, deploys, stage branches) from shared services, with controls to trigger a sweep and tear down branches. Three templates + a README; see `dashboard/README.md`. |

The agent-driven layer lives in `../QA-SWEEP.md` (the sweep brief,
including the findings file contract) and the commands
`.senior-mode/commands/qa-sweep.md`, `.senior-mode/commands/stage.md`, and
`.senior-mode/commands/ship.md` (the full verified-ship loop:
stage -> sweep -> fix -> re-sweep until clean -> push).

## Hard-won operational rules (encode these, they cost real hours)

1. **Never sweep during a rolling release.** Mid-rollout, requests mix
   old and new builds and you get false-positive React hydration
   errors (#418). Check deploy age first.
2. **Sweep with a member-role login, but know its blind spot:** admin
   only APIs return 403 before they can 500, so an admin-only server
   bug passes a member sweep. Cover admin paths in CI (where the test
   user is an admin) or run a second sweep with admin credentials.
3. **The sweep's best catch class is silent ones:** pages that render
   politely over a 500ing data fetch, and tables that exist in prod
   but in no journaled migration (drift that only bites
   journal-bootstrapped DBs and restores).
4. **Promote, don't gate, agent findings:** when an exploratory agent
   pass finds a flow worth protecting, turn it into a scripted spec
   that runs on every push. Agents scout; deterministic tests gate.
