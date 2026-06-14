# generate-secrets.ps1 — Create production Kubernetes secrets for StayLedger
# Usage: Run from stayledger-shared/ root with required parameters
# WARNING: Do NOT commit this file with real values filled in.
# Store secrets in a password manager and run locally.
#
# Example:
#   .\k8s\prd\generate-secrets.ps1 `
#     -PostgresPassword "yourStrongPassword" `
#     -JwtSecret "your64PlusCharJwtSecretHere..." `
#     -JwtRefreshSecret "your64PlusCharRefreshSecretHere..." `
#     -FrontendUrl "https://stayledger.tekcent.com" `
#     -AzureOpenAiEndpoint "https://your-resource.cognitiveservices.azure.com" `
#     -AzureOpenAiApiKey "your-azure-openai-key"

param(
    [Parameter(Mandatory=$true)]
    [string]$PostgresPassword,

    [Parameter(Mandatory=$true)]
    [string]$JwtSecret,

    [Parameter(Mandatory=$true)]
    [string]$JwtRefreshSecret,

    [Parameter(Mandatory=$true)]
    [string]$FrontendUrl,

    [Parameter(Mandatory=$true)]
    [string]$AzureOpenAiEndpoint,

    [Parameter(Mandatory=$true)]
    [string]$AzureOpenAiApiKey,

    [string]$RedisPassword = "",
    [string]$MetricsAuthToken = "",
    [string]$SmtpHost = "",
    [string]$SmtpPort = "587",
    [string]$SmtpUser = "",
    [string]$SmtpPassword = "",
    [string]$SmtpFrom = ""
)

if ($JwtSecret.Length -lt 64) {
    Write-Error "JWT_SECRET must be at least 64 characters. Got: $($JwtSecret.Length)"
    exit 1
}
if ($JwtRefreshSecret.Length -lt 64) {
    Write-Error "JWT_REFRESH_SECRET must be at least 64 characters. Got: $($JwtRefreshSecret.Length)"
    exit 1
}
if ($FrontendUrl -match "localhost|127\.0\.0\.1|placeholder|changeme|example") {
    Write-Error "FRONTEND_URL appears to be a placeholder: $FrontendUrl"
    exit 1
}
if ($AzureOpenAiEndpoint -match "localhost|placeholder|changeme|YOUR_RESOURCE") {
    Write-Error "AZURE_OPENAI_ENDPOINT appears to be a placeholder: $AzureOpenAiEndpoint"
    exit 1
}

Add-Type -AssemblyName System.Web
$DbPassword = [System.Web.HttpUtility]::UrlEncode($PostgresPassword)
# Runtime URL routes through PgBouncer; pgbouncer=true disables prepared statements (required for transaction pooling).
$DatabaseUrl = "postgresql://stayledger:${DbPassword}@stayledger-pgbouncer.stayledger.svc.cluster.local:5432/stayledger?schema=public&pgbouncer=true&connection_limit=20&pool_timeout=10&statement_timeout=30000"
# Direct URL bypasses PgBouncer — used by Prisma migrations (directUrl in schema.prisma).
$DirectDatabaseUrl = "postgresql://stayledger:${DbPassword}@stayledger-postgres.stayledger.svc.cluster.local:5432/stayledger?schema=public&connection_limit=2&statement_timeout=60000"
$AzureBaseUrl = $AzureOpenAiEndpoint.TrimEnd('/') + "/openai/v1"

Write-Host "Creating stayledger namespace..." -ForegroundColor Cyan
kubectl apply -f k8s/prd/namespace.yaml

Write-Host "Creating stayledger-secrets..." -ForegroundColor Cyan

$SecretArgs = @(
    "create", "secret", "generic", "stayledger-secrets",
    "--namespace=stayledger",
    "--save-config",
    "--dry-run=client",
    "-o=yaml",
    "--from-literal=database-url=$DatabaseUrl",
    "--from-literal=direct-database-url=$DirectDatabaseUrl",
    "--from-literal=jwt-secret=$JwtSecret",
    "--from-literal=jwt-refresh-secret=$JwtRefreshSecret",
    "--from-literal=postgres-password=$PostgresPassword",
    "--from-literal=frontend-url=$FrontendUrl",
    "--from-literal=azure-openai-endpoint=$AzureOpenAiEndpoint",
    "--from-literal=azure-openai-api-key=$AzureOpenAiApiKey",
    "--from-literal=openai-base-url=$AzureBaseUrl"
)

if ($RedisPassword -ne "") {
    $RedisUrl = "redis://:${RedisPassword}@stayledger-redis.stayledger.svc.cluster.local:6379"
    $SecretArgs += "--from-literal=redis-password=$RedisPassword"
    $SecretArgs += "--from-literal=redis-url=$RedisUrl"
}
if ($MetricsAuthToken -ne "") {
    $SecretArgs += "--from-literal=metrics-auth-token=$MetricsAuthToken"
}
if ($SmtpHost -ne "") {
    $SecretArgs += "--from-literal=smtp-host=$SmtpHost"
    $SecretArgs += "--from-literal=smtp-port=$SmtpPort"
    $SecretArgs += "--from-literal=smtp-user=$SmtpUser"
    $SecretArgs += "--from-literal=smtp-password=$SmtpPassword"
    $SecretArgs += "--from-literal=smtp-from=$SmtpFrom"
}

& kubectl @SecretArgs | kubectl apply -f -

# Create the PgBouncer userlist secret (separate from the main secret so the Deployment
# can mount userlist.txt read-only without exposing other credentials).
Write-Host "Creating stayledger-pgbouncer-secret..." -ForegroundColor Cyan
$UserlistContent = "`"stayledger`" `"$PostgresPassword`""
& kubectl create secret generic stayledger-pgbouncer-secret `
    --namespace=stayledger `
    --save-config `
    --dry-run=client `
    -o=yaml `
    "--from-literal=userlist.txt=$UserlistContent" `
    | kubectl apply -f -

Write-Host ""
Write-Host "Secrets created. Verify (no values shown):" -ForegroundColor Green
kubectl get secret stayledger-secrets -n stayledger
kubectl get secret stayledger-pgbouncer-secret -n stayledger
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Green
Write-Host "  1. kubectl apply -f k8s/prd/storage.yaml"
Write-Host "  2. kubectl apply -f k8s/prd/postgres.yaml"
Write-Host "  3. kubectl apply -f k8s/prd/pgbouncer.yaml"
Write-Host "  4. kubectl apply -f k8s/prd/redis.yaml"
Write-Host "  5. kubectl apply -f stayledger-api/k8s/prd/deployment.yaml"
Write-Host "  6. kubectl apply -f stayledger-admin-web/k8s/prd/deployment.yaml"
