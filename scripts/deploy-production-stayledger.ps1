# Production deployment for stayledger k3s cluster (context: stayledger).
#
# Targets:
#   PMS:          app.stayledger.io, api.stayledger.io  (namespace stayledger)
#   AI Assistant: assistant.stayledger.io, api-assistant.stayledger.io (namespace stayledger-ai-assistant)
#
# Usage (from stayledger-infra/ root):
#   .\scripts\deploy-production-stayledger.ps1 -Phase preflight
#   .\scripts\deploy-production-stayledger.ps1 -Phase pms-datastores -SkipSecrets
#   .\scripts\deploy-production-stayledger.ps1 -Phase pms-app
#   .\scripts\deploy-production-stayledger.ps1 -Phase ai-assistant
#   .\scripts\deploy-production-stayledger.ps1 -Phase ingress
#   .\scripts\deploy-production-stayledger.ps1 -Phase all

[CmdletBinding()]
param(
  [ValidateSet('preflight', 'pms-datastores', 'pms-app', 'ai-assistant', 'ingress', 'all')]
  [string]$Phase = 'preflight',

  [string]$KubectlContext = 'stayledger',
  [string]$PmsApiTag = 'f1b2e27',
  [string]$PmsAdminWebTag = 'c4fadf3',
  [string]$AiApiTag = 'cvefix-e2a914e',
  [string]$AiFrontendTag = 'sha-golive1000712',

  [switch]$SkipSecrets,
  [switch]$SkipNodePrep,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$InfraRoot = Resolve-Path (Join-Path $PSScriptRoot '..')

function Invoke-Kubectl {
  param([string[]]$Args)
  $display = @('kubectl', "--context=$KubectlContext") + $Args
  Write-Host ">> $($display -join ' ')" -ForegroundColor DarkGray
  if ($DryRun) { return }
  & kubectl --context=$KubectlContext @Args
  if ($LASTEXITCODE -ne 0) { throw "kubectl failed: $($display -join ' ')" }
}

function Test-SecretExists {
  param([string]$Namespace, [string]$Name)
  if ($DryRun) { return $true }
  $null = kubectl --context=$KubectlContext get secret $Name -n $Namespace 2>$null
  return $LASTEXITCODE -eq 0
}

function Apply-MigrationJob {
  param([string]$Namespace, [string]$ImageTag, [string]$JobFile, [string]$SecretName)
  $raw = Get-Content $JobFile -Raw
  $raw = $raw -replace 'COMMIT_SHA', $ImageTag
  $raw = $raw -replace 'stayledger-staging-secrets', $SecretName
  $raw = $raw -replace '(?m)^\s*argocd\.argoproj\.io/.*\r?\n', ''
  $tmp = Join-Path $env:TEMP "stayledger-db-migrate-$Namespace.yaml"
  Set-Content -Path $tmp -Value $raw -Encoding UTF8
  Invoke-Kubectl @('delete', 'job', 'stayledger-db-migrate', '-n', $Namespace, '--ignore-not-found')
  Invoke-Kubectl @('apply', '-f', $tmp)
  Invoke-Kubectl @('wait', '--for=condition=complete', 'job/stayledger-db-migrate', '-n', $Namespace, '--timeout=300s')
  Invoke-Kubectl @('logs', 'job/stayledger-db-migrate', '-n', $Namespace, '--tail=40')
}

Write-Host ''
Write-Host "=== StayLedger production deploy (cluster: $KubectlContext) ===" -ForegroundColor Cyan
Write-Host "PMS images: api=$PmsApiTag admin-web=$PmsAdminWebTag"
Write-Host "AI images:  api=$AiApiTag frontend=$AiFrontendTag"
Write-Host ''

Push-Location $InfraRoot
try {
  if ($Phase -in @('preflight', 'all')) {
    Write-Host '[preflight] context + cluster' -ForegroundColor Yellow
    Invoke-Kubectl @('config', 'current-context')
    Invoke-Kubectl @('get', 'nodes', '-o', 'wide')
    Invoke-Kubectl @('get', 'clusterissuer')
    Invoke-Kubectl @('get', 'ns', 'stayledger', 'stayledger-ai-assistant', '--ignore-not-found')

    Write-Host ''
    Write-Host '[preflight] DNS (run before ingress phase):' -ForegroundColor Yellow
    foreach ($dnsHost in @('app.stayledger.io', 'api.stayledger.io', 'assistant.stayledger.io', 'api-assistant.stayledger.io')) {
      try {
        $r = Resolve-DnsName $dnsHost -ErrorAction Stop | Select-Object -First 1
        Write-Host "  OK  $dnsHost -> $($r.IPAddress)" -ForegroundColor Green
      } catch {
        Write-Host "  MISSING  $dnsHost" -ForegroundColor Red
      }
    }

    if (-not $SkipNodePrep) {
      Write-Host ''
      Write-Host '[preflight] Node paths required on stayledger node:' -ForegroundColor Yellow
      @(
        '/mnt/data/stayledger/postgres',
        '/mnt/data/stayledger/redis',
        '/mnt/data/stayledger/guest-documents',
        '/mnt/data/stayledger/ai-assistant/postgres',
        '/mnt/data/stayledger/ai-assistant/postgres-backup',
        '/mnt/data/stayledger/ai-assistant/redis'
      ) | ForEach-Object { Write-Host "  $_" }
    }
  }

  if ($Phase -in @('pms-datastores', 'all')) {
    if (-not $SkipSecrets) {
      if (-not (Test-SecretExists -Namespace 'stayledger' -Name 'stayledger-secrets')) {
        throw 'stayledger-secrets missing. Run stayledger-shared/datastores/production/generate-secrets.ps1 first.'
      }
      Write-Host '[pms-datastores] stayledger-secrets present' -ForegroundColor Green
    }

    Write-Host '[pms-datastores] storage + PVC' -ForegroundColor Yellow
    Invoke-Kubectl @('apply', '-f', 'stayledger-shared/datastores/production/namespace.yaml')
    Invoke-Kubectl @('apply', '-f', 'stayledger-shared/datastores/production/storage-stayledger-k3s.yaml')
    Invoke-Kubectl @('apply', '-k', 'stayledger-api/production/', '--dry-run=client', '-o', 'yaml') | Out-Null
    Invoke-Kubectl @('apply', '-f', 'stayledger-api/production/guest-documents-pvc.yaml')

    Write-Host '[pms-datastores] postgres / pgbouncer / redis' -ForegroundColor Yellow
    Invoke-Kubectl @('apply', '-f', 'stayledger-shared/datastores/production/postgres.yaml')
    Invoke-Kubectl @('apply', '-f', 'stayledger-shared/datastores/production/pgbouncer.yaml')
    Invoke-Kubectl @('apply', '-f', 'stayledger-shared/datastores/production/redis.yaml')
    Invoke-Kubectl @('rollout', 'status', 'statefulset/stayledger-postgres', '-n', 'stayledger', '--timeout=300s')
  }

  if ($Phase -in @('pms-app', 'all')) {
    Write-Host '[pms-app] migrate + deploy api/admin-web' -ForegroundColor Yellow
    if (-not (Test-SecretExists -Namespace 'stayledger' -Name 'stayledger-secrets')) {
      throw 'stayledger-secrets missing - run generate-secrets.ps1 first.'
    }

    $migrateFile = Join-Path $InfraRoot 'stayledger-api/production/migration-job.yaml'
    Apply-MigrationJob -Namespace 'stayledger' -ImageTag $PmsApiTag -JobFile $migrateFile -SecretName 'stayledger-secrets'

    Invoke-Kubectl @('apply', '-k', 'stayledger-api/production/')
    Invoke-Kubectl @('apply', '-k', 'stayledger-admin-web/production/')
    Invoke-Kubectl @('set', 'image', 'deployment/stayledger-api', "api=putin111/stayledger-api:$PmsApiTag", '-n', 'stayledger')
    Invoke-Kubectl @('set', 'image', 'deployment/stayledger-ai-worker', "ai-worker=putin111/stayledger-api:$PmsApiTag", '-n', 'stayledger')
    Invoke-Kubectl @('set', 'image', 'deployment/stayledger-admin-web', "admin-web=putin111/stayledger-admin-web:$PmsAdminWebTag", '-n', 'stayledger')
    Invoke-Kubectl @('rollout', 'status', 'deployment/stayledger-api', '-n', 'stayledger', '--timeout=300s')
    Invoke-Kubectl @('rollout', 'status', 'deployment/stayledger-ai-worker', '-n', 'stayledger', '--timeout=300s')
    Invoke-Kubectl @('rollout', 'status', 'deployment/stayledger-admin-web', '-n', 'stayledger', '--timeout=300s')
  }

  if ($Phase -in @('ai-assistant', 'all')) {
    Write-Host '[ai-assistant] secrets + namespace' -ForegroundColor Yellow
    $aiNs = 'stayledger-ai-assistant'
    Invoke-Kubectl @('apply', '-f', 'stayledger-ai-assistant/base/namespace.yaml')

    $requiredSecrets = @(
      'stayledger-ai-assistant/base/datastores/redis-secret.yaml',
      'stayledger-ai-assistant/base/datastores/pgbouncer-secret.yaml',
      'stayledger-ai-assistant/base/app/hotel-assistant-api-secret.yaml',
      'stayledger-ai-assistant/base/app/hotel-assistant-smtp-secret.yaml',
      'stayledger-ai-assistant/base/app/hotel-assistant-frontend-secret.yaml'
    )
    foreach ($rel in $requiredSecrets) {
      $path = Join-Path $InfraRoot $rel
      if (-not (Test-Path $path)) {
        throw "Missing secret file: $rel (copy from example yaml, gitignored)."
      }
      Invoke-Kubectl @('apply', '-f', $path)
    }

    Write-Host '[ai-assistant] optional one-time postgres bootstrap (skip if DB already initialized)' -ForegroundColor Yellow
    Write-Host "  kubectl --context=$KubectlContext apply -f stayledger-ai-assistant/base/datastores/postgres-bootstrap-job.yaml"

    Write-Host '[ai-assistant] alembic migration job' -ForegroundColor Yellow
    Invoke-Kubectl @('delete', 'job', 'alembic-upgrade', '-n', $aiNs, '--ignore-not-found')
    Invoke-Kubectl @('apply', '-f', 'stayledger-ai-assistant/base/app/alembic-upgrade-job.yaml')
    Invoke-Kubectl @('wait', '--for=condition=complete', 'job/alembic-upgrade', '-n', $aiNs, '--timeout=600s')

    Write-Host '[ai-assistant] apply production overlay' -ForegroundColor Yellow
    Invoke-Kubectl @('apply', '-k', 'stayledger-ai-assistant/production/')
    Invoke-Kubectl @('set', 'image', 'deployment/hotel-assistant-api', "api=putin111/stayledger-ai-assistant:$AiApiTag", '-n', $aiNs)
    Invoke-Kubectl @('set', 'image', 'deployment/hotel-assistant-channel-worker', "channel-worker=putin111/stayledger-ai-assistant:$AiApiTag", '-n', $aiNs)
    Invoke-Kubectl @('set', 'image', 'deployment/hotel-assistant-webhook-worker', "webhook-worker=putin111/stayledger-ai-assistant:$AiApiTag", '-n', $aiNs)
    Invoke-Kubectl @('set', 'image', 'deployment/hotel-assistant-metrics-aggregator', "metrics-aggregator=putin111/stayledger-ai-assistant:$AiApiTag", '-n', $aiNs)
    Invoke-Kubectl @('set', 'image', 'deployment/hotel-assistant-frontend', "frontend=putin111/stayledger-ai-assistant-frontend:$AiFrontendTag", '-n', $aiNs)
    Invoke-Kubectl @('rollout', 'status', 'deployment/hotel-assistant-api', '-n', $aiNs, '--timeout=300s')
    Invoke-Kubectl @('rollout', 'status', 'deployment/hotel-assistant-frontend', '-n', $aiNs, '--timeout=300s')
  }

  if ($Phase -in @('ingress', 'all')) {
    Write-Host '[ingress] PMS + AI assistant Traefik+TLS (requires DNS -> 103.20.96.122)' -ForegroundColor Yellow
    # Ingress resources are included in kustomize overlays; re-apply overlays to keep
    # ClusterIP services + Ingress in sync (no NodePort).
    Invoke-Kubectl @('apply', '-k', 'stayledger-api/production/')
    Invoke-Kubectl @('apply', '-k', 'stayledger-admin-web/production/')
    Invoke-Kubectl @('apply', '-k', 'stayledger-ai-assistant/production/')
    Write-Host "Watch certs: kubectl --context=$KubectlContext get certificate -A"
  }

  Write-Host ''
  Write-Host "Done phase: $Phase" -ForegroundColor Green
} finally {
  Pop-Location
}
