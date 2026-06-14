# Generate and apply Kubernetes secrets for StayLedger
# Run BEFORE applying postgres.yaml / redis.yaml
# Usage:
#   .\k8s\generate-secrets.ps1 -Environment staging
#   .\k8s\generate-secrets.ps1 -Environment prd

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("staging", "prd")]
    [string]$Environment
)

$namespace  = if ($Environment -eq "prd") { "stayledger" } else { "stayledger-staging" }
$secretName = if ($Environment -eq "prd") { "stayledger-secrets" } else { "stayledger-staging-secrets" }

Write-Host ""
Write-Host "Environment : $Environment"
Write-Host "Namespace   : $namespace"
Write-Host "Secret name : $secretName"
Write-Host ""

# Verify kubectl can reach the cluster
kubectl cluster-info --request-timeout=5s | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "kubectl cannot reach the cluster. Check your kubeconfig and VPN."
    exit 1
}

# Verify namespace exists
$nsExists = kubectl get namespace $namespace --ignore-not-found 2>$null
if (-not $nsExists) {
    Write-Error "Namespace '$namespace' not found. Apply namespace.yaml first:`n  kubectl apply -f k8s/$Environment/namespace.yaml"
    exit 1
}

$postgresPasswordSec = Read-Host -AsSecureString "POSTGRES_PASSWORD"
$redisPasswordSec    = Read-Host -AsSecureString "REDIS_PASSWORD"

$pgPlain    = [System.Net.NetworkCredential]::new("", $postgresPasswordSec).Password
$redisPlain = [System.Net.NetworkCredential]::new("", $redisPasswordSec).Password

if ([string]::IsNullOrWhiteSpace($pgPlain) -or [string]::IsNullOrWhiteSpace($redisPlain)) {
    Write-Error "Passwords must not be empty. Aborted."
    exit 1
}

# --dry-run=client | apply is idempotent: creates or updates in one command
kubectl create secret generic $secretName `
    --namespace $namespace `
    --from-literal=postgres-password=$pgPlain `
    --from-literal=redis-password=$redisPlain `
    --dry-run=client -o yaml | kubectl apply -f -

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to apply secret '$secretName'."
    exit 1
}

Write-Host ""
Write-Host "Secret '$secretName' ready in namespace '$namespace'."
