# install.ps1 — Install ArgoCD v3.4.3 on hkk8s-hub-master (single-node staging).
#
# Prerequisites:
#   - kubectl configured and pointing at the target cluster
#   - Internet access to download the ArgoCD manifest from GitHub
#
# Usage (from repo root):
#   .\argocd\install\install.ps1
#
# The script is idempotent — safe to re-run.

$ErrorActionPreference = "Stop"

$ARGOCD_VERSION   = "v3.4.3"
$ARGOCD_NAMESPACE = "argocd"
$INSTALL_URL      = "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"
$CRD_URL          = "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/crds/applicationset-crd.yaml"
$SCRIPT_DIR       = Split-Path -Parent $MyInvocation.MyCommand.Path

function Step([int]$n, [string]$msg) {
    Write-Host ""
    Write-Host "==> [$n] $msg" -ForegroundColor Cyan
}

Step 1 "Creating namespace $ARGOCD_NAMESPACE"
kubectl create namespace $ARGOCD_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

Step 2 "Applying ArgoCD $ARGOCD_VERSION install manifest"
kubectl apply -n $ARGOCD_NAMESPACE -f $INSTALL_URL

# The applicationsets CRD has annotations that exceed the 262 kB client-side limit.
# Apply it separately using server-side apply to avoid the error.
Step 3 "Applying applicationsets CRD via server-side apply"
kubectl apply --server-side --force-conflicts -f $CRD_URL

Step 4 "Applying insecure-mode config (plain HTTP, no TLS)"
kubectl apply -f (Join-Path $SCRIPT_DIR "argocd-params.yaml")

Step 5 "Waiting for argocd-server rollout (up to 5 min)"
kubectl rollout status deployment/argocd-server -n $ARGOCD_NAMESPACE --timeout=300s

Step 6 "Exposing ArgoCD server via NodePort 30082"
kubectl apply -f (Join-Path $SCRIPT_DIR "argocd-nodeport.yaml")

Step 7 "Restarting argocd-server to pick up insecure-mode config"
kubectl rollout restart deployment/argocd-server -n $ARGOCD_NAMESPACE
kubectl rollout status deployment/argocd-server -n $ARGOCD_NAMESPACE --timeout=120s

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Green
Write-Host " ArgoCD $ARGOCD_VERSION installed successfully" -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  UI:       http://10.89.1.40:30082"
Write-Host "  Username: admin"

try {
    $encoded = kubectl -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret `
        -o jsonpath="{.data.password}" 2>$null
    $password = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded))
    Write-Host "  Password: $password" -ForegroundColor Yellow
} catch {
    Write-Host "  Password: (secret not found — already initialised)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor White
Write-Host "  1. Open http://10.89.1.40:30082 and change the admin password."
Write-Host "  2. Add GitHub PAT credentials (see argocd/README.md Section 5)."
Write-Host "  3. Deploy staging applications:"
Write-Host "       kubectl apply -f argocd/staging/app-infrastructure.yaml"
Write-Host "       kubectl apply -f argocd/staging/app-api.yaml"
Write-Host "       kubectl apply -f argocd/staging/app-admin-web.yaml"
