<#
.SYNOPSIS
  Repair staging RBAC E2E fixtures (prop-test-hanoi) without full destructive refresh.

.DESCRIPTION
  - Ensures E2E seed data + deterministic RBAC invoice labels (INV-HANOI-RBAC-001)
  - Runs phase-pack seeds for AI quota / capability fixtures
  - Clears Redis auth cache
  - Aligns stayledger-e2e .env.staging E2E_TEST_PROPERTY_ID=prop-test-hanoi

.EXAMPLE
  .\stayledger-infra\scripts\repair-staging-rbac-fixtures.ps1
#>
param(
  [string]$Namespace = 'stayledger-staging',
  [int]$PostgresLocalPort = 5433,
  [string]$RbacPropertyId = 'prop-test-hanoi',
  [string]$PhasePackPropertyId = 'capability_growth_property_1',
  [switch]$SkipPhasePack,
  [switch]$SkipEnvUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path (Join-Path $RepoRoot 'stayledger-api'))) {
  $RepoRoot = Split-Path $PSScriptRoot -Parent
}
$DbDir = Join-Path $RepoRoot 'stayledger-api\db'
$E2eDir = Join-Path $RepoRoot 'stayledger-e2e'

function Decode-Secret([string]$Key) {
  $b64 = kubectl get secret stayledger-staging-secrets -n $Namespace -o "jsonpath={.data.$Key}"
  if (-not $b64) { throw "Secret key not found: $Key" }
  return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))
}

function Wait-Port([int]$Port, [int]$TimeoutSec = 45) {
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    try {
      $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $Port)
      $client.Close()
      return
    } catch {
      Start-Sleep -Milliseconds 500
    }
  }
  throw "Timed out waiting for localhost:$Port"
}

if (-not $SkipEnvUpdate) {
  $rbacCredentialMap = [ordered]@{
    'E2E_TEST_PROPERTY_ID' = $RbacPropertyId
    'E2E_SUPER_ADMIN_EMAIL' = 'superadmin.capability@stayledger.test'
    'E2E_SYSTEM_ADMIN_EMAIL' = 'systemadmin.capability@stayledger.test'
    'E2E_ADMIN_EMAIL' = 'manager@stayledger.test'
    'E2E_PROPERTY_MANAGER_EMAIL' = 'manager@stayledger.test'
    'E2E_FRONT_DESK_EMAIL' = 'frontdesk@stayledger.test'
    'E2E_HOUSEKEEPING_EMAIL' = 'housekeeping@stayledger.test'
    'E2E_ACCOUNTING_EMAIL' = 'accounting@stayledger.test'
    'E2E_READ_ONLY_EMAIL' = 'readonly@stayledger.test'
  }
  $envFiles = @(
    (Join-Path $E2eDir '.env.staging'),
    (Join-Path $E2eDir '.env.staging.example')
  )
  foreach ($file in $envFiles) {
    if (-not (Test-Path $file)) { continue }
    $content = Get-Content $file -Raw
    $updated = $content
    foreach ($entry in $rbacCredentialMap.GetEnumerator()) {
      $pattern = "$($entry.Key)=.*"
      $replacement = "$($entry.Key)=$($entry.Value)"
      $updated = $updated -replace $pattern, $replacement
    }
    if ($updated -ne $content) {
      Set-Content -Path $file -Value $updated -NoNewline
      Write-Host "Updated RBAC env mapping in $file" -ForegroundColor Green
    }
  }
}

Write-Host 'Port-forwarding Postgres for RBAC fixture repair...' -ForegroundColor Cyan
$directUrl = Decode-Secret 'direct-database-url'
$databaseUrl = $directUrl -replace '@[^/]+/', "@127.0.0.1:${PostgresLocalPort}/"

$pfPg = Start-Process -FilePath kubectl -ArgumentList @(
  'port-forward', '-n', $Namespace, 'pod/stayledger-postgres-0', "${PostgresLocalPort}:5432"
) -PassThru -WindowStyle Hidden

try {
  Wait-Port -Port $PostgresLocalPort
  $env:DATABASE_URL = $databaseUrl
  $env:SEED_TARGET = 'staging'
  $env:SEED_STAGING_PORT_FORWARD = 'true'
  $env:E2E_REPAIR_PROPERTY_ID = $RbacPropertyId

  Push-Location $DbDir
  try {
    Write-Host '[1/4] seed:e2e (non-destructive upsert)' -ForegroundColor Yellow
    pnpm seed:e2e
    if ($LASTEXITCODE -ne 0) { throw 'seed:e2e failed' }

    Write-Host '[2/4] repair:rbac-display-labels' -ForegroundColor Yellow
    pnpm repair:rbac-display-labels
    if ($LASTEXITCODE -ne 0) { throw 'repair:rbac-display-labels failed' }

    Write-Host '[3/4] seed:pms-capability (platform + RBAC compatibility)' -ForegroundColor Yellow
    pnpm seed:pms-capability
    if ($LASTEXITCODE -ne 0) { throw 'seed:pms-capability failed' }
  } finally {
    Pop-Location
  }
} finally {
  if ($pfPg -and -not $pfPg.HasExited) {
    Stop-Process -Id $pfPg.Id -Force -ErrorAction SilentlyContinue
  }
}

if (-not $SkipPhasePack) {
  $phasePack = Join-Path $DbDir 'scripts\seed-staging-phase-pack.ps1'
  if (Test-Path $phasePack) {
    Write-Host "[4/5] seed-staging-phase-pack ($PhasePackPropertyId)" -ForegroundColor Yellow
    & $phasePack -PropertyId $PhasePackPropertyId
    if ($LASTEXITCODE -ne 0) { throw 'seed-staging-phase-pack failed' }
  }
}

if ($PhasePackPropertyId -eq 'capability_growth_property_1') {
  Write-Host '[5/5] repair:capability-growth-ai-quota (reset warn-scenario usage)' -ForegroundColor Yellow
  $directUrl = Decode-Secret 'direct-database-url'
  $databaseUrl = $directUrl -replace '@[^/]+/', "@127.0.0.1:${PostgresLocalPort}/"
  $pfPgQuota = Start-Process -FilePath kubectl -ArgumentList @(
    'port-forward', '-n', $Namespace, 'pod/stayledger-postgres-0', "${PostgresLocalPort}:5432"
  ) -PassThru -WindowStyle Hidden
  try {
    Wait-Port -Port $PostgresLocalPort
    $env:DATABASE_URL = $databaseUrl
    $env:SEED_TARGET = 'staging'
    Push-Location $DbDir
    try {
      pnpm repair:capability-growth-ai-quota
      if ($LASTEXITCODE -ne 0) { throw 'repair:capability-growth-ai-quota failed' }
    } finally {
      Pop-Location
    }
  } finally {
    if ($pfPgQuota -and -not $pfPgQuota.HasExited) {
      Stop-Process -Id $pfPgQuota.Id -Force -ErrorAction SilentlyContinue
    }
  }
}

Write-Host 'Flushing Redis auth cache...' -ForegroundColor Cyan
$redisPassword = Decode-Secret 'redis-password'
kubectl exec -n $Namespace deploy/stayledger-redis -- redis-cli -a $redisPassword FLUSHDB 2>&1 | Out-Null

Write-Host 'RBAC fixture repair complete.' -ForegroundColor Green
Write-Host "  RBAC property: $RbacPropertyId"
Write-Host "  Re-run: cd stayledger-e2e; `$env:E2E_ENV='staging'; playwright test --config=playwright.rbac.config.ts"
