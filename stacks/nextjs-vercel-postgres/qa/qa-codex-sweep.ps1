# TEMPLATE - qa-codex-sweep.ps1: launch codex (or adapt for another agent
# CLI) as the QA sweeper against a deployed target. The verify leg of the
# /ship loop. Adjust the ADJUST-marked lines.
#
# Usage:
#   pwsh scripts/qa-codex-sweep.ps1                          # sweep prod
#   pwsh scripts/qa-codex-sweep.ps1 -Target https://...      # sweep staging
#   pwsh scripts/qa-codex-sweep.ps1 -Layer1Only              # deterministic only
#   pwsh scripts/qa-codex-sweep.ps1 -Headed                  # visible browser window
#
# Reads QA_AGENT_EMAIL / QA_AGENT_PASSWORD / QA_TENANT_ID /
# VERCEL_AUTOMATION_BYPASS_SECRET from apps/web/.env.local and exports
# them to the codex process env (never into the prompt). Codex follows
# QA-SWEEP.md and writes qa-findings.md per its contract.
#
# Each run's findings are archived to qa-findings-archive/<ts>.md so the
# orchestration dashboard can show sweep history.
#
# Exit code: 0 when the findings verdict is CLEAN, 2 when findings exist,
# 1 on launcher/codex failure.
param(
  [string]$Target = "https://your-app.example", # ADJUST
  [string]$Out = "qa-findings.md",
  [switch]$Layer1Only,
  [switch]$Headed
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
  Write-Error "[qa-codex-sweep] codex CLI not installed."
  exit 1
}

# Export QA credentials from the env file into THIS process env so codex
# child processes (playwright, node) inherit them. Never echo values.
$envFile = Join-Path $repoRoot "apps/web/.env.local"
foreach ($key in @("QA_AGENT_EMAIL", "QA_AGENT_PASSWORD", "QA_TENANT_ID", "VERCEL_AUTOMATION_BYPASS_SECRET")) {
  $line = Select-String -Path $envFile -Pattern "^$key=" | Select-Object -First 1
  if ($line) {
    $value = ($line.Line -split "=", 2)[1].Trim('"')
    [Environment]::SetEnvironmentVariable($key, $value, "Process")
  }
}
if (-not $env:QA_AGENT_PASSWORD -or -not $env:QA_TENANT_ID) {
  Write-Error "[qa-codex-sweep] QA_AGENT_PASSWORD / QA_TENANT_ID missing from apps/web/.env.local (run seed-qa-tenant.ts)."
  exit 1
}
# The playwright fixtures read TEST_* names.
$env:TEST_USER_EMAIL = $env:QA_AGENT_EMAIL
$env:TEST_USER_PASSWORD = $env:QA_AGENT_PASSWORD
$env:TEST_TENANT_ID = $env:QA_TENANT_ID
$env:BASE_URL = $Target
if ($Headed) { $env:PWHEADED = "1" } else { $env:PWHEADED = "0" }

if (Test-Path $Out) { Remove-Item $Out -Force -Confirm:$false }

$layerNote = if ($Layer1Only) {
  "Run ONLY Layer 1 (the deterministic sweep). Skip Layer 2."
} else {
  "Run Layer 1 first, then the Layer 2 exploratory circuit."
}
$headedNote = if ($Headed) {
  "Run in HEADED mode: PWHEADED=1 is set, so Playwright opens a visible browser window. Pass --headed to any playwright invocation and do NOT add --headless; the operator is watching."
} else { "" }

$prompt = @"
You are the QA sweeper for this repo. Read QA-SWEEP.md at the repo root
and follow it exactly, including its identity boundaries and its
findings file contract.

Target: $Target
$layerNote
$headedNote

The QA credentials are already in your process environment
(TEST_USER_EMAIL, TEST_USER_PASSWORD, TEST_TENANT_ID, BASE_URL, and
VERCEL_AUTOMATION_BYPASS_SECRET if the target is a protected preview).
Never print the password or bypass secret.

Layer 1: run the deterministic sweep command from the brief (the
pages-smoke playwright spec in apps/web). Layer 2: drive the flows by
writing and running small Playwright scripts with the same storage
state the spec produces (apps/web/e2e/.auth/state.json after Layer 1),
or by signing in once via POST /api/auth/sign-in/email. Honor the
boundaries: member login only, QA sandbox tenant only, no document
deletions, no email sends.

When done, write qa-findings.md at the repo root in the exact contract
format from QA-SWEEP.md, then print the verdict line as your last
output line.
"@

# Sandbox note: the sweep must exec playwright and reach the network. Use
# the least-permissive codex sandbox that allows both on your machine
# (workspace-write with network access where the sandbox helper works;
# danger-full-access if the helper is unavailable; same trust as a shell).
#
# Prompt is fed via stdin with the `-` token, NOT as a positional arg. When
# codex exec gets a positional prompt in a non-TTY context (background launch,
# CI, the /ship loop), it treats stdin as piped and blocks forever on
# "Reading additional input from stdin..." waiting for an EOF that never comes.
# Piping the prompt closes stdin and lets codex start.
$prompt | & codex exec --sandbox danger-full-access -c features.hooks=false -
if ($LASTEXITCODE -ne 0) {
  Write-Error "[qa-codex-sweep] codex exec failed (exit $LASTEXITCODE)."
  exit 1
}

if (-not (Test-Path $Out)) {
  Write-Error "[qa-codex-sweep] codex did not write $Out."
  exit 1
}

# Archive this run so the dashboard can show history (latest stays at $Out).
$archiveDir = Join-Path $repoRoot "qa-findings-archive"
if (-not (Test-Path $archiveDir)) { New-Item -ItemType Directory -Path $archiveDir | Out-Null }
$stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
Copy-Item $Out (Join-Path $archiveDir "$stamp.md") -Force

$verdictLine = Select-String -Path $Out -Pattern "verdict\s*:" -CaseSensitive:$false | Select-Object -First 1
$verdict = if ($verdictLine) { $verdictLine.Line } else { "verdict: MISSING" }
"[qa-codex-sweep] $verdict (archived $stamp)"
if ($verdict -match "CLEAN") { exit 0 } else { exit 2 }
