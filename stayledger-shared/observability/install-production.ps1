# Install observability stack on stayledger k3s production cluster.
# Prerequisites: kubectl context stayledger, helm, cert-manager, Traefik.
#
# Usage (from stayledger-infra/stayledger-shared/observability):
#   .\install-production.ps1 -GrafanaPassword '<strong-password>'
#
param(
  [Parameter(Mandatory = $true)]
  [string]$GrafanaPassword,

  [string]$KubectlContext = 'stayledger',

  [switch]$SkipHelm,

  # Opt-in only: production Grafana is ClusterIP + port-forward by default (no public Ingress).
  [switch]$EnableGrafanaIngress
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$ctx = $KubectlContext

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) { throw 'kubectl missing' }
if (-not (Get-Command helm -ErrorAction SilentlyContinue)) { throw 'helm missing' }

Write-Host "=== Context: $ctx ===" -ForegroundColor Cyan
kubectl config use-context $ctx
if ($LASTEXITCODE -ne 0) { throw 'failed to switch context' }

Write-Host "`n=== Node host paths for observability PVs ===" -ForegroundColor Cyan
$debugYaml = @'
apiVersion: v1
kind: Pod
metadata:
  name: obs-node-prep
  namespace: default
spec:
  restartPolicy: Never
  nodeName: stayledger
  containers:
  - name: prep
    image: busybox:1.36
    command: ["sleep", "300"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: host
      mountPath: /host
  volumes:
  - name: host
    hostPath:
      path: /
'@
$tmpDebug = Join-Path $env:TEMP 'obs-node-prep.yaml'
Set-Content $tmpDebug $debugYaml -Encoding UTF8
kubectl --context=$ctx delete pod obs-node-prep -n default --ignore-not-found
kubectl --context=$ctx apply -f $tmpDebug
kubectl --context=$ctx wait --for=condition=Ready pod/obs-node-prep -n default --timeout=90s
kubectl --context=$ctx exec -n default obs-node-prep -- sh -c @'
mkdir -p /host/mnt/data/stayledger/observability/prometheus \
         /host/mnt/data/stayledger/observability/alertmanager \
         /host/mnt/data/stayledger/observability/grafana \
         /host/mnt/data/stayledger/observability/loki \
         /host/mnt/data/stayledger/observability/tempo
chown -R 65534:65534 /host/mnt/data/stayledger/observability
chown -R 472:472 /host/mnt/data/stayledger/observability/grafana
ls -la /host/mnt/data/stayledger/observability
'@

Write-Host "`n=== Namespace, storage, RBAC, quotas ===" -ForegroundColor Cyan
kubectl --context=$ctx apply -f (Join-Path $Root 'namespace.yaml')
if ($LASTEXITCODE -ne 0) { throw 'namespace apply failed' }
kubectl --context=$ctx apply -f (Join-Path $Root 'storage-pvs-stayledger-k3s.yaml')
kubectl --context=$ctx apply -f (Join-Path $Root 'resource-quotas.yaml')
kubectl --context=$ctx apply -f (Join-Path $Root 'rbac.yaml')
kubectl --context=$ctx apply -f (Join-Path $Root 'pod-disruption-budgets.yaml')

Write-Host "`n=== Metrics auth secret for Prometheus scrape of API ===" -ForegroundColor Cyan
$metricsTokenB64 = kubectl --context=$ctx get secret stayledger-secrets -n stayledger -o jsonpath='{.data.metrics-auth-token}'
if (-not $metricsTokenB64) { throw 'stayledger-secrets.metrics-auth-token missing' }
$metricsToken = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($metricsTokenB64))
# Mounted by Prometheus (observability) and referenced by API ServiceMonitor (stayledger).
foreach ($ns in @('observability', 'stayledger')) {
  kubectl --context=$ctx -n $ns create secret generic stayledger-metrics-auth `
    --from-literal=token=$metricsToken `
    --dry-run=client -o yaml | kubectl --context=$ctx apply -f -
}

Write-Host "`n=== Postgres exporter DSN secret ===" -ForegroundColor Cyan
$pgPassB64 = kubectl --context=$ctx get secret stayledger-secrets -n stayledger -o jsonpath='{.data.postgres-password}'
$pgPass = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pgPassB64))
$enc = [Uri]::EscapeDataString($pgPass)
$dsn = "postgresql://stayledger:${enc}@stayledger-postgres.stayledger.svc.cluster.local:5432/stayledger?sslmode=disable"
kubectl --context=$ctx -n observability create secret generic postgres-exporter-secret `
  --from-literal=data-source-name=$dsn `
  --dry-run=client -o yaml | kubectl --context=$ctx apply -f -

if (-not $SkipHelm) {
  Write-Host "`n=== Helm repos ===" -ForegroundColor Cyan
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>$null
  helm repo add grafana https://grafana.github.io/helm-charts 2>$null
  helm repo update | Out-Host

  # Install kube-prometheus-stack FIRST so monitoring.coreos.com CRDs (ServiceMonitor) exist.
  Write-Host "`n=== kube-prometheus-stack (kps) - installs CRDs ===" -ForegroundColor Cyan
  helm upgrade --install kps prometheus-community/kube-prometheus-stack `
    -n observability `
    --kube-context $ctx `
    -f (Join-Path $Root 'helm/kube-prometheus-stack-values.yaml') `
    -f (Join-Path $Root 'helm/kube-prometheus-stack-values-production.yaml') `
    --set "grafana.adminPassword=$GrafanaPassword" `
    --timeout 25m --wait
  if ($LASTEXITCODE -ne 0) { throw 'kps helm failed' }

  Write-Host "Resetting Grafana admin password..."
  kubectl --context=$ctx -n observability exec deploy/kps-grafana -c grafana -- `
    grafana cli admin reset-admin-password "$GrafanaPassword"

  Write-Host "`n=== Loki ===" -ForegroundColor Cyan
  helm upgrade --install loki grafana/loki `
    -n observability `
    --kube-context $ctx `
    --version 7.0.0 `
    -f (Join-Path $Root 'helm/loki-values-v3.yaml') `
    -f (Join-Path $Root 'helm/loki-values-production.yaml') `
    --timeout 20m --wait
  if ($LASTEXITCODE -ne 0) { throw 'loki helm failed' }

  Write-Host "`n=== Promtail ===" -ForegroundColor Cyan
  helm upgrade --install promtail grafana/promtail `
    -n observability `
    --kube-context $ctx `
    --version 6.17.1 `
    -f (Join-Path $Root 'helm/promtail-values.yaml') `
    --set serviceMonitor.enabled=false `
    --timeout 20m --wait
  if ($LASTEXITCODE -ne 0) { throw 'promtail helm failed' }

  Write-Host "`n=== Tempo ===" -ForegroundColor Cyan
  helm upgrade --install tempo grafana/tempo `
    -n observability `
    --kube-context $ctx `
    --version 1.24.4 `
    -f (Join-Path $Root 'helm/tempo-values.yaml') `
    -f (Join-Path $Root 'helm/tempo-values-production.yaml') `
    --timeout 20m --wait
  if ($LASTEXITCODE -ne 0) { Write-Warning 'tempo helm failed - continuing' }
}

Write-Host "`n=== Dashboards, exporters, otel, alerts ===" -ForegroundColor Cyan
kubectl --context=$ctx apply -f (Join-Path $Root 'grafana/dashboards/stayledger-pms')
kubectl --context=$ctx apply -f (Join-Path $Root 'grafana/dashboards/stayledger-ai-assistant')
kubectl --context=$ctx apply -f (Join-Path $Root 'exporters/production')
kubectl --context=$ctx apply -f (Join-Path $Root 'otel-collector')
kubectl --context=$ctx apply -f (Join-Path $Root 'alerting/stayledger-rules.yaml')
kubectl --context=$ctx apply -f (Join-Path $Root 'alerting/prometheus-recording-rules.yaml')
kubectl --context=$ctx apply -f (Join-Path $Root 'alerting/prometheus-infrastructure-alerts.yaml')
kubectl --context=$ctx apply -f (Join-Path $Root 'alerting/guest-documents-alerts.yaml')
kubectl --context=$ctx apply -f (Join-Path $Root 'alerting/stayledger-readiness-alerts.yaml')

Write-Host "`n=== API ServiceMonitors ===" -ForegroundColor Cyan
$apiSm = Join-Path $Root '../production/servicemonitor.yaml'
if (Test-Path $apiSm) { kubectl --context=$ctx apply -f $apiSm }
$apiRules = Join-Path $Root '../production/prometheusrule.yaml'
if (Test-Path $apiRules) { kubectl --context=$ctx apply -f $apiRules }
$aiSm = Join-Path $Root '../../stayledger-api/base/ai-worker-servicemonitor.yaml'
if (Test-Path $aiSm) { kubectl --context=$ctx apply -n stayledger -f $aiSm }

if ($EnableGrafanaIngress) {
  Write-Host "`n=== Grafana Ingress (opt-in) ===" -ForegroundColor Cyan
  kubectl --context=$ctx apply -f (Join-Path $Root 'ingress-grafana-production.yaml')
} else {
  Write-Host "`n=== Grafana: ClusterIP only (no public Ingress) ===" -ForegroundColor Cyan
  kubectl --context=$ctx delete ingress kps-grafana -n observability --ignore-not-found
  kubectl --context=$ctx delete certificate stayledger-grafana-tls -n observability --ignore-not-found
}

Write-Host "`n=== Wait core rollouts ===" -ForegroundColor Cyan
kubectl --context=$ctx rollout status deployment/kps-grafana -n observability --timeout=300s
kubectl --context=$ctx get pods -n observability -o wide
kubectl --context=$ctx get pvc -n observability
kubectl --context=$ctx get svc,ingress -n observability

kubectl --context=$ctx delete pod obs-node-prep -n default --ignore-not-found

Write-Host ""
Write-Host "Observability production install finished." -ForegroundColor Green
Write-Host "  Grafana (port-forward): kubectl --context stayledger -n observability port-forward svc/kps-grafana 3000:80"
Write-Host "  Login: admin / <password you supplied>"
Write-Host "  Prometheus:            kubectl --context stayledger -n observability port-forward svc/kps-prometheus 9090:9090"
