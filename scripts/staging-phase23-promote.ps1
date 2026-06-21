# Post-Phase Readiness — staging DB + config promotion (Wave A/B).
# Run from repo root after kubectl access to stayledger-staging.
#
# Prerequisites:
#   - DATABASE_URL pointing at staging Postgres (port-forward or VPN)
#   - SEED_STAGING_CONFIRM=true for destructive refresh
#
# Usage:
#   .\stayledger-infra\scripts\staging-phase23-promote.ps1 -MigrateOnly
#   .\stayledger-infra\scripts\staging-phase23-promote.ps1 -FullSeed

param(
  [switch]$MigrateOnly,
  [switch]$FullSeed
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path (Join-Path $repoRoot 'stayledger-api'))) {
  $repoRoot = Split-Path $PSScriptRoot -Parent
}

Write-Host "StayLedger staging Phase 2-3 promotion" -ForegroundColor Cyan
Write-Host "Repo root: $repoRoot"

Push-Location (Join-Path $repoRoot 'stayledger-api')
try {
  Write-Host "`n▶ prisma migrate deploy" -ForegroundColor Yellow
  pnpm --filter @stayledger/db exec prisma migrate deploy

  if ($MigrateOnly) {
    Write-Host "`nDone (migrate only)." -ForegroundColor Green
    return
  }

  Write-Host "`n▶ addon + phase seeds" -ForegroundColor Yellow
  pnpm --filter @stayledger/db seed:addon-catalog
  pnpm --filter @stayledger/db seed:channel-manager
  pnpm --filter @stayledger/db seed:overage-billing
  $env:AI_OPS_TIER = 'pro'
  pnpm --filter @stayledger/db seed:ai-ops-property

  if ($FullSeed) {
    Write-Host "`n▶ full staging refresh (destructive)" -ForegroundColor Yellow
    $env:SEED_TARGET = 'staging'
    if (-not $env:SEED_STAGING_CONFIRM) {
      Write-Host "Set SEED_STAGING_CONFIRM=true to run full refresh." -ForegroundColor Red
      exit 1
    }
    pnpm --filter @stayledger/db seed:staging:refresh
  }
}
finally {
  Pop-Location
}

Write-Host "`nNext steps:" -ForegroundColor Green
Write-Host "  1. kubectl apply -f stayledger-infra/stayledger-api/staging/configmap.yaml"
Write-Host "  2. kubectl apply -f stayledger-infra/stayledger-admin-web/staging/deployment.yaml"
Write-Host "  3. kubectl rollout restart deployment/stayledger-api -n stayledger-staging"
Write-Host "  4. kubectl rollout restart deployment/stayledger-admin-web -n stayledger-staging"
Write-Host "  5. cd stayledger-e2e && pnpm test:e2e:phase22 && pnpm test:e2e:phase23 && pnpm test:e2e:phase31 && pnpm test:e2e:phase33 && pnpm test:e2e:phase34"
