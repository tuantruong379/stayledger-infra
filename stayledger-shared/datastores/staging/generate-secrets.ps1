# generate-secrets.ps1 — Create staging Kubernetes secrets for StayLedger
# Usage: Run from stayledger-shared/ root with required parameters
# WARNING: Do NOT commit this file with real values filled in.
# Store secrets in a password manager and run locally.
#
# Example:
#   .\k8s\staging\generate-secrets.ps1 `
#     -PostgresPassword "yourStrongPassword" `
#     -JwtSecret "your64PlusCharJwtSecretHere..." `
#     -JwtRefreshSecret "your64PlusCharRefreshSecretHere..." `
#     -FrontendUrl "https://stg-app.stayledger.io" `
#     -AzureOpenAiEndpoint "https://stayledger-resource.openai.azure.com" `
#     -AzureOpenAiApiKey "your-azure-openai-key" `
#     -RedisPassword "yourRedisPassword"

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

# Validate JWT secret lengths (must be >= 64 chars)
if ($JwtSecret.Length -lt 64) {
    Write-Error "JWT_SECRET must be at least 64 characters. Got: $($JwtSecret.Length)"
    exit 1
}
if ($JwtRefreshSecret.Length -lt 64) {
    Write-Error "JWT_REFRESH_SECRET must be at least 64 characters. Got: $($JwtRefreshSecret.Length)"
    exit 1
}

# Validate FRONTEND_URL is not localhost or placeholder
if ($FrontendUrl -match "localhost|127\.0\.0\.1|placeholder|changeme|example") {
    Write-Error "FRONTEND_URL appears to be a placeholder: $FrontendUrl"
    exit 1
}

# Validate Azure OpenAI endpoint
if ($AzureOpenAiEndpoint -match "localhost|placeholder|changeme|YOUR_RESOURCE") {
    Write-Error "AZURE_OPENAI_ENDPOINT appears to be a placeholder: $AzureOpenAiEndpoint"
    exit 1
}
if ($AzureOpenAiApiKey -match "^__REQUIRES|^your-|^changeme") {
    Write-Error "AZURE_OPENAI_API_KEY appears to be a placeholder."
    exit 1
}

# Build DATABASE_URL and REDIS_URL from credentials
Add-Type -AssemblyName System.Web
$DbPassword = [System.Web.HttpUtility]::UrlEncode($PostgresPassword)
# Runtime URL routes through PgBouncer; pgbouncer=true disables prepared statements (required for transaction pooling).
$DatabaseUrl = "postgresql://stayledger_staging:${DbPassword}@stayledger-pgbouncer.stayledger-staging.svc.cluster.local:5432/stayledger_staging?schema=public&pgbouncer=true&connection_limit=10&pool_timeout=10&statement_timeout=30000"
# Direct URL bypasses PgBouncer — used by Prisma migrations (directUrl in schema.prisma).
$DirectDatabaseUrl = "postgresql://stayledger_staging:${DbPassword}@stayledger-postgres.stayledger-staging.svc.cluster.local:5432/stayledger_staging?schema=public&connection_limit=2&statement_timeout=60000"

Write-Host "Creating stayledger-staging namespace..." -ForegroundColor Cyan
kubectl apply -f k8s/staging/namespace.yaml

Write-Host "Creating stayledger-staging-secrets..." -ForegroundColor Cyan

# Build kubectl create secret command
$SecretArgs = @(
    "create", "secret", "generic", "stayledger-staging-secrets",
    "--namespace=stayledger-staging",
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
    "--from-literal=azure-openai-api-key=$AzureOpenAiApiKey"
)

if ($RedisPassword -ne "") {
    $RedisUrl = "redis://:${RedisPassword}@stayledger-redis.stayledger-staging.svc.cluster.local:6379"
    $SecretArgs += "--from-literal=redis-password=$RedisPassword"
    $SecretArgs += "--from-literal=redis-url=$RedisUrl"
}

if ($MetricsAuthToken -eq "") {
    # Auto-generate when omitted — required for production-like staging metrics auth.
    $MetricsBytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($MetricsBytes)
    $MetricsAuthToken = [Convert]::ToBase64String($MetricsBytes)
    Write-Host "Generated metrics-auth-token (not printed)." -ForegroundColor Yellow
}
$SecretArgs += "--from-literal=metrics-auth-token=$MetricsAuthToken"

if ($SmtpHost -ne "") {
    $SecretArgs += "--from-literal=smtp-host=$SmtpHost"
    $SecretArgs += "--from-literal=smtp-port=$SmtpPort"
    $SecretArgs += "--from-literal=smtp-user=$SmtpUser"
    $SecretArgs += "--from-literal=smtp-password=$SmtpPassword"
    $SecretArgs += "--from-literal=smtp-from=$SmtpFrom"
}

# Dry-run first, then apply
& kubectl @SecretArgs | kubectl apply -f -

# Create the PgBouncer userlist secret (separate from the main secret so the Deployment
# can mount userlist.txt read-only without exposing other credentials).
Write-Host "Creating stayledger-pgbouncer-secret..." -ForegroundColor Cyan
$UserlistContent = "`"stayledger_staging`" `"$PostgresPassword`""
& kubectl create secret generic stayledger-pgbouncer-secret `
    --namespace=stayledger-staging `
    --save-config `
    --dry-run=client `
    -o=yaml `
    "--from-literal=userlist.txt=$UserlistContent" `
    | kubectl apply -f -

Write-Host ""
Write-Host "Secrets created. Verify (no values should be shown):" -ForegroundColor Green
kubectl get secret stayledger-staging-secrets -n stayledger-staging
kubectl get secret stayledger-pgbouncer-secret -n stayledger-staging
Write-Host ""
Write-Host "Done. Next steps:" -ForegroundColor Green
Write-Host "  1. kubectl apply -f k8s/staging/storage.yaml"
Write-Host "  2. kubectl apply -f k8s/staging/postgres.yaml"
Write-Host "  3. kubectl apply -f k8s/staging/pgbouncer.yaml"
Write-Host "  4. kubectl apply -f k8s/staging/redis.yaml"
Write-Host "  5. kubectl apply -f stayledger-api/k8s/staging-deployment.yaml"
Write-Host "  6. kubectl apply -f stayledger-admin-web/k8s/staging-deployment.yaml"
Write-Host ""
Write-Host "After infra is up, run DB migration job:"
Write-Host "  kubectl wait --for=condition=complete job/stayledger-db-migrate -n stayledger-staging --timeout=120s"
