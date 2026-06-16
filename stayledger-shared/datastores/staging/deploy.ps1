# Deploy StayLedger staging to hkk8s-hub-master
# Prerequisites:
#   1. kubectl configured and pointing at the cluster
#   2. Host directories exist on the node (run once manually):
#        kubectl debug node/hkk8s-hub-master -it --image=busybox:1.36 -- \
#          sh -c "mkdir -p /mnt/data/stayledger-staging/postgres /mnt/data/stayledger-staging/redis"
#   3. Secrets created:
#        .\k8s\generate-secrets.ps1 -Environment staging

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

function Apply($file) {
    Write-Host "  kubectl apply $file"
    kubectl apply -f $file
    if ($LASTEXITCODE -ne 0) { throw "Apply failed: $file" }
}

function WaitReady($kind, $name, $namespace, [int]$timeoutSec = 120) {
    Write-Host "  Waiting for $kind/$name to be ready (timeout ${timeoutSec}s)..."
    kubectl rollout status $kind/$name -n $namespace --timeout="${timeoutSec}s"
    if ($LASTEXITCODE -ne 0) { throw "$kind/$name did not become ready in time" }
}

# --- Verify cluster access ---
Write-Host "[1/5] Checking cluster connectivity..."
kubectl cluster-info --request-timeout=5s | Out-Null
if ($LASTEXITCODE -ne 0) { throw "kubectl cannot reach the cluster." }

# --- Verify secrets exist ---
Write-Host "[2/5] Verifying staging secrets..."
$secret = kubectl get secret stayledger-staging-secrets -n stayledger-staging --ignore-not-found 2>$null
if (-not $secret) {
    Write-Error "Secret 'stayledger-staging-secrets' not found in namespace 'stayledger-staging'."
    Write-Error "Run: .\k8s\generate-secrets.ps1 -Environment staging"
    exit 1
}

# --- Namespace + Storage ---
Write-Host "[3/5] Applying namespace and storage..."
Apply "$DIR\..\staging\namespace.yaml"
Apply "$DIR\..\staging\storage.yaml"

# --- PostgreSQL ---
Write-Host "[4/5] Deploying PostgreSQL..."
Apply "$DIR\..\staging\postgres.yaml"
WaitReady "statefulset" "stayledger-postgres" "stayledger-staging" 180

# --- Redis ---
Write-Host "[5/5] Deploying Redis..."
Apply "$DIR\..\staging\redis.yaml"
WaitReady "deployment" "stayledger-redis" "stayledger-staging" 120

# --- PostgreSQL backup CronJob (optional; requires backup PV path on node) ---
Write-Host "[6/6] Applying PostgreSQL backup CronJob..."
Apply "$DIR\..\staging\postgres-backup-cronjob.yaml"

# --- Status summary ---
Write-Host ""
Write-Host "=== Staging deploy complete ==="
kubectl get pods -n stayledger-staging
Write-Host ""
kubectl get pvc -n stayledger-staging
