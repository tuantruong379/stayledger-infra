<#
.SYNOPSIS
  Install StayLedger observability stack (Prometheus, Grafana, Loki, Promtail, Tempo) on staging k8s.

.EXAMPLE
  .\install.ps1 -GrafanaPassword 'admin'
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$GrafanaPassword,

  [switch]$SkipHelm
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

function Require-Command($Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $Name"
  }
}

Require-Command kubectl
Require-Command helm

Write-Host "Applying observability namespace, storage, RBAC, and limits..."
kubectl apply -f (Join-Path $Root 'namespace.yaml')
kubectl apply -f (Join-Path $Root 'storage-pvs.yaml')
kubectl apply -f (Join-Path $Root 'resource-quotas.yaml')
kubectl apply -f (Join-Path $Root 'rbac.yaml')
kubectl apply -f (Join-Path $Root 'pod-disruption-budgets.yaml')

if (-not $SkipHelm) {
  Write-Host "Adding Helm repos..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>$null
  helm repo add grafana https://grafana.github.io/helm-charts 2>$null
  helm repo update

  $helmArgs = @('--timeout', '15m', '--wait')

  Write-Host "Installing/upgrading Loki 3.x (single binary)..."
  # Pin chart version — loki-7.0.0 template changes can hit StatefulSet immutable-field errors on re-upgrade.
  helm upgrade --install loki grafana/loki `
    -n observability `
    --version 7.0.0 `
    -f (Join-Path $Root 'helm/loki-values-v3.yaml') `
    @helmArgs 2>&1 | Out-Host
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "Loki upgrade failed (often StatefulSet immutable fields). Pods may still run on prior revision — check: helm history loki -n observability"
  }

  Write-Host "Installing/upgrading Promtail..."
  helm upgrade --install promtail grafana/promtail `
    -n observability `
    --version 6.17.1 `
    -f (Join-Path $Root 'helm/promtail-values.yaml') `
    @helmArgs

  Write-Host "Installing/upgrading Tempo..."
  helm upgrade --install tempo grafana/tempo `
    -n observability `
    --version 1.24.4 `
    -f (Join-Path $Root 'helm/tempo-values.yaml') `
    @helmArgs 2>&1 | Out-Host
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "Tempo upgrade failed (often StatefulSet immutable fields). Pods may still run on prior revision — check: helm history tempo -n observability"
  }

  Write-Host "Installing/upgrading kube-prometheus-stack (release: kps)..."
  helm upgrade --install kps prometheus-community/kube-prometheus-stack `
    -n observability `
    -f (Join-Path $Root 'helm/kube-prometheus-stack-values.yaml') `
    --set "grafana.adminPassword=$GrafanaPassword" `
    @helmArgs

  Write-Host "Resetting Grafana admin password in grafana.db (Helm --set only seeds empty PVC)..."
  kubectl -n observability exec deploy/kps-grafana -c grafana -- `
    grafana cli admin reset-admin-password "$GrafanaPassword"
}

Write-Host "Applying dashboards, exporters, otel collector, and alert rules..."
kubectl apply -f (Join-Path $Root 'grafana/dashboards/stayledger-pms')
kubectl apply -f (Join-Path $Root 'grafana/dashboards/stayledger-ai-assistant')
kubectl apply -f (Join-Path $Root 'exporters')
kubectl apply -f (Join-Path $Root 'otel-collector')
kubectl apply -f (Join-Path $Root 'alerting')

Write-Host "Waiting for core pods..."
kubectl -n observability rollout status deployment/kps-grafana --timeout=300s 2>$null
kubectl -n observability rollout status deployment/otel-collector --timeout=300s 2>$null

Write-Host ""
Write-Host "Observability stack applied."
Write-Host "  Grafana:     http://<node-ip>:30030  (admin / password you supplied)"
Write-Host "  Prometheus:  http://<node-ip>:30090"
Write-Host "  Dashboards:  StayLedger PMS and StayLedger AI Assistant folders (auto-provisioned from ConfigMaps)"
Write-Host ""
Write-Host "Secrets (copy from examples/ locally, not committed):"
Write-Host "  examples/grafana-admin-secret.example.yaml"
Write-Host "  examples/alertmanager-secrets.example.yaml"
