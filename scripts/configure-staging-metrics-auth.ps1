<#
.SYNOPSIS
  Enable METRICS_AUTH_TOKEN on staging API and block public /api/metrics at ingress.

.DESCRIPTION
  1. Generates (or accepts) a bearer token for Prometheus scrape auth
  2. Patches stayledger-staging-secrets.metrics-auth-token (does not rotate other keys)
  3. Creates observability/stayledger-metrics-auth for in-cluster Prometheus
  4. Applies staging API ingress server-snippet (403 on /api/metrics)
  5. Restarts API + AI worker; optionally upgrades kube-prometheus-stack
  6. Verifies public curl returns 401/403

.EXAMPLE
  .\stayledger-infra\scripts\configure-staging-metrics-auth.ps1

.EXAMPLE
  .\stayledger-infra\scripts\configure-staging-metrics-auth.ps1 -SkipHelmUpgrade
#>
param(
  [string]$Namespace = 'stayledger-staging',
  [string]$ObservabilityNamespace = 'observability',
  [string]$MetricsAuthToken = '',
  [switch]$SkipHelmUpgrade,
  [switch]$SkipIngressApply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path (Join-Path $RepoRoot 'stayledger-infra'))) {
  $RepoRoot = Split-Path $PSScriptRoot -Parent
}

function Require-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $Name"
  }
}

Require-Command kubectl

if ([string]::IsNullOrWhiteSpace($MetricsAuthToken)) {
  $bytes = New-Object byte[] 32
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $MetricsAuthToken = [Convert]::ToBase64String($bytes)
  Write-Host 'Generated new metrics-auth-token (value not printed).' -ForegroundColor Yellow
}

Write-Host 'Patching stayledger-staging-secrets.metrics-auth-token...' -ForegroundColor Cyan
$patchJson = (@{ stringData = @{ 'metrics-auth-token' = $MetricsAuthToken } } | ConvertTo-Json -Compress)
kubectl patch secret stayledger-staging-secrets -n $Namespace --type=merge -p $patchJson | Out-Host

Write-Host 'Creating stayledger-metrics-auth secrets...' -ForegroundColor Cyan
foreach ($ns in @($ObservabilityNamespace, $Namespace)) {
  kubectl create secret generic stayledger-metrics-auth `
    --namespace=$ns `
    --from-literal=token=$MetricsAuthToken `
    --dry-run=client -o yaml | kubectl apply -f - | Out-Host
}

if (-not $SkipIngressApply) {
  $ingressFile = Join-Path $RepoRoot 'stayledger-infra\stayledger-shared\staging\ingress.yaml'
  if (-not (Test-Path $ingressFile)) {
    throw "Ingress manifest not found: $ingressFile"
  }
  Write-Host 'Applying staging ingress (blocks public /api/metrics)...' -ForegroundColor Cyan
  kubectl apply -f $ingressFile | Out-Host
}

Write-Host 'Restarting API and AI worker to pick up METRICS_AUTH_TOKEN...' -ForegroundColor Cyan
kubectl rollout restart deployment/stayledger-api -n $Namespace | Out-Host
kubectl rollout restart deployment/stayledger-ai-worker -n $Namespace | Out-Host
kubectl rollout status deployment/stayledger-api -n $Namespace --timeout=300s | Out-Host
kubectl rollout status deployment/stayledger-ai-worker -n $Namespace --timeout=300s | Out-Host

if (-not $SkipHelmUpgrade) {
  if (Get-Command helm -ErrorAction SilentlyContinue) {
    $valuesFile = Join-Path $RepoRoot 'stayledger-infra\stayledger-shared\observability\helm\kube-prometheus-stack-values.yaml'
    if (Test-Path $valuesFile) {
      Write-Host 'Upgrading kube-prometheus-stack scrape auth (bearer_token_file)...' -ForegroundColor Cyan
      helm upgrade --install kps prometheus-community/kube-prometheus-stack `
        -n $ObservabilityNamespace `
        -f $valuesFile `
        --timeout 15m `
        --wait 2>&1 | Out-Host
    } else {
      Write-Warning "Prometheus values not found at $valuesFile - run helm upgrade manually."
    }
  } else {
    Write-Warning "helm not found - skip Prometheus scrape auth upgrade. Re-run without -SkipHelmUpgrade when helm is available."
  }
}

Write-Host 'Verifying public metrics exposure...' -ForegroundColor Cyan
Start-Sleep -Seconds 5
try {
  $resp = Invoke-WebRequest -Uri 'https://stg-api.stayledger.io/api/metrics' -SkipCertificateCheck -TimeoutSec 20 -ErrorAction Stop
  $code = [int]$resp.StatusCode
} catch {
  if ($null -ne $_.Exception.Response) {
    $code = [int]$_.Exception.Response.StatusCode
  } else {
    $code = 0
  }
}

if ($code -in 401, 403) {
  Write-Host "PASS: public /api/metrics returned $code" -ForegroundColor Green
} else {
  Write-Error "FAIL: public /api/metrics returned $code (expected 401 or 403)"
  exit 1
}

Write-Host ""
Write-Host "Staging metrics auth configured." -ForegroundColor Green
Write-Host "  - API env: METRICS_AUTH_TOKEN from stayledger-staging-secrets"
Write-Host "  - Ingress: /api/metrics blocked at stg-api.stayledger.io"
Write-Host "  - Prometheus: scrapes in-cluster with bearer token (after helm upgrade)"
