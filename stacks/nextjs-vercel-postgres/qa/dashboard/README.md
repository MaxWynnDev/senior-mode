# Ship pipeline dashboard (template)

A dev-gated page that surfaces the whole /ship pipeline in one place.
The orchestration runs locally (codex, stage scripts, findings files),
so a prod-deployed dashboard reads only SHARED services and degrades
gracefully when a token is absent. Three files, all under 400 LOC:

| Template | Install as | What it is |
|---|---|---|
| `ship-status.ts.template` | `src/lib/ship-status.ts` | Read-only aggregator: GitHub Actions runs (gating CI, nightly sweep, deploy hook) + Neon stage branches. Trigger-sweep and teardown-branch helpers. Pure env-driven; no secrets returned to client. |
| `ship-status-route.ts.template` | `src/app/api/v1/<admin>/ship-status/route.ts` | GET (aggregate) + POST (dispatch sweep / teardown branch), behind your dev gate. |
| `ship-dashboard.page.tsx.template` | `src/app/<admin>/ship/page.tsx` | Client dashboard: status strip + CI/nightly/deploy/branches panels + controls. Manual refresh only (keeps GitHub/Neon API calls down). |

## Project dependencies to wire (the ADJUST points)

- **Dev gate:** the route uses `requireDev(ctx, req)` from your
  `@/lib/api-utils`. Swap for your platform-admin gate. Keep it
  session-only (reject API keys) and 2FA/IP-hardened.
- **Env vars the aggregator reads** (server-side, in the deployed
  runtime): `GITHUB_REPO` (owner/name), `GITHUB_TOKEN` (Actions:read;
  Actions:write to also trigger sweeps), `NEON_PROJECT_ID`,
  `NEON_API_KEY` (add to the prod env to light up the branches panel).
- **Workflow file names:** the aggregator queries `ci.yml`,
  `qa-sweep.yml`, `deploy-on-ci-green.yml`. Rename to match your repo.
- **UI imports:** the page uses `@/components/ui/button`, a
  `relativeTime` helper from `@/lib/utils`, the `analytics-panel` CSS
  class, and `lucide-react` icons. Swap for your design system.
- **Non-Vercel deploys:** the "deploy hook fires" panel reads a GitHub
  workflow; if you deploy another way, point it at your deploy signal
  or drop the panel.

## Why prod-deployed and not local

The durable pipeline state (CI, nightly sweeps, deploys, branches)
lives in shared services reachable from anywhere, so a dev on any
machine sees the same truth. The local-only parts (ad-hoc headed
sweeps where you watch the agent drive a browser) stay in the terminal
by nature. The dashboard says so in its own footer.
