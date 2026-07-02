# generate-secrets.ps1 — Create production Kubernetes secrets for StayLedger PMS
# Usage: Run from stayledger-infra/ root with required parameters
# WARNING: Do NOT commit this file with real values filled in.
# Store secrets in a password manager and run locally.
#
# Example:
#   .\stayledger-shared\datastores\production\generate-secrets.ps1 `
#     -PostgresPassword "yourStrongPassword" `
#     -JwtSecret "your64PlusCharJwtSecretHere..." `
#     -JwtRefreshSecret "your64PlusCharRefreshSecretHere..." `
#     -FrontendUrl "https://app.stayledger.io" `
#     -AzureOpenAiEndpoint "https://your-resource.cognitiveservices.azure.com" `
#     -AzureOpenAiApiKey "your-azure-openai-key" `
#     -ExternalSigningEncKey "$(openssl rand -hex 32)" `
#     -EncryptionKey "$(openssl rand -hex 32)" `
#     -DocumentBackupPassword "$(openssl rand -base64 48)" `
#     -SmtpUser "AKIAIOSFODNN7EXAMPLE" `
#     -SmtpPassword "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

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

    # AES-256-GCM key for encrypting external API signing secrets at rest.
    # REQUIRED: EXTERNAL_API_SIGNATURE_REQUIRED=true — without this, the server cannot
    # provision/verify signing secrets and all external API calls return 401.
    # Generate: openssl rand -hex 32   (must be exactly 64 hex characters = 32 bytes)
    [Parameter(Mandatory=$true)]
    [string]$ExternalSigningEncKey,

    # AES-256 key for encrypting sensitive data fields at rest.
    # Generate: openssl rand -hex 32   (must be exactly 64 hex characters = 32 bytes)
    [Parameter(Mandatory=$true)]
    [string]$EncryptionKey,

    # Passphrase for AES-256-CBC encryption of guest document S3 backup archives.
    # Generate: openssl rand -base64 48
    # Also stored in stayledger-document-backup-s3.encryption-passphrase (see below).
    [Parameter(Mandatory=$true)]
    [string]$DocumentBackupPassword,

    [string]$RedisPassword = "",
    [string]$MetricsAuthToken = "",
    [string]$SmtpHost = "",
    [string]$SmtpPort = "465",
    [string]$SmtpUser = "",
    [string]$SmtpPassword = "",
    [string]$SmtpFrom = "",

    # S3 credentials for document backup (stayledger-document-backup-s3 secret).
    # If omitted, create this secret manually before enabling the document backup CronJob.
    [string]$DocumentBackupBucket = "prd-stayledger-pms",
    [string]$DocumentBackupS3AccessKeyId = "",
    [string]$DocumentBackupS3SecretAccessKey = "",
    [string]$DocumentBackupS3Region = "ap-southeast-1"
)

# Validation
if ($JwtSecret.Length -lt 64) {
    Write-Error "JWT_SECRET must be at least 64 characters. Got: $($JwtSecret.Length)"
    exit 1
}
if ($JwtRefreshSecret.Length -lt 64) {
    Write-Error "JWT_REFRESH_SECRET must be at least 64 characters. Got: $($JwtRefreshSecret.Length)"
    exit 1
}
if ($FrontendUrl -match "localhost|127\.0\.0\.1|placeholder|changeme|example|tekcent") {
    Write-Error "FRONTEND_URL appears to be a placeholder or staging value: $FrontendUrl"
    exit 1
}
if ($AzureOpenAiEndpoint -match "localhost|placeholder|changeme|YOUR_RESOURCE") {
    Write-Error "AZURE_OPENAI_ENDPOINT appears to be a placeholder: $AzureOpenAiEndpoint"
    exit 1
}
if ($ExternalSigningEncKey.Length -ne 64 -or $ExternalSigningEncKey -notmatch '^[0-9a-fA-F]+$') {
    Write-Error "EXTERNAL_SIGNING_ENC_KEY must be exactly 64 hex characters (32 bytes). Generate with: openssl rand -hex 32"
    exit 1
}
if ($EncryptionKey.Length -ne 64 -or $EncryptionKey -notmatch '^[0-9a-fA-F]+$') {
    Write-Error "ENCRYPTION_KEY must be exactly 64 hex characters (32 bytes). Generate with: openssl rand -hex 32"
    exit 1
}
if ($DocumentBackupPassword.Length -lt 16) {
    Write-Error "DOCUMENT_BACKUP_PASSWORD is too short (minimum 16 characters). Generate with: openssl rand -base64 48"
    exit 1
}

Add-Type -AssemblyName System.Web
$DbPassword = [System.Web.HttpUtility]::UrlEncode($PostgresPassword)
# Runtime URL routes through PgBouncer; pgbouncer=true disables prepared statements (required for transaction pooling).
$DatabaseUrl = "postgresql://stayledger:${DbPassword}@stayledger-pgbouncer.stayledger.svc.cluster.local:5432/stayledger?schema=public&pgbouncer=true&connection_limit=20&pool_timeout=10&statement_timeout=30000"
# Direct URL bypasses PgBouncer — used by Prisma migrations (directUrl in schema.prisma).
$DirectDatabaseUrl = "postgresql://stayledger:${DbPassword}@stayledger-postgres.stayledger.svc.cluster.local:5432/stayledger?schema=public&connection_limit=2&statement_timeout=60000"
$AzureBaseUrl = $AzureOpenAiEndpoint.TrimEnd('/') + "/openai/v1"

Write-Host "Applying namespace..." -ForegroundColor Cyan
kubectl apply -f stayledger-shared/datastores/production/namespace.yaml

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
    "--from-literal=openai-base-url=$AzureBaseUrl",
    "--from-literal=external-signing-enc-key=$ExternalSigningEncKey",
    "--from-literal=encryption-key=$EncryptionKey",
    "--from-literal=document-backup-password=$DocumentBackupPassword"
)

if ($RedisPassword -ne "") {
    $RedisUrl = "redis://:${RedisPassword}@stayledger-redis.stayledger.svc.cluster.local:6379"
    $SecretArgs += "--from-literal=redis-password=$RedisPassword"
    $SecretArgs += "--from-literal=redis-url=$RedisUrl"
}
if ($MetricsAuthToken -ne "") {
    $SecretArgs += "--from-literal=metrics-auth-token=$MetricsAuthToken"
}
if ($SmtpUser -ne "") {
    $SecretArgs += "--from-literal=smtp-user=$SmtpUser"
    $SecretArgs += "--from-literal=smtp-password=$SmtpPassword"
}
if ($SmtpFrom -ne "") {
    $SecretArgs += "--from-literal=smtp-from=$SmtpFrom"
}

& kubectl @SecretArgs | kubectl apply -f -

Write-Host "Creating stayledger-pgbouncer-secret..." -ForegroundColor Cyan
$UserlistContent = "`"stayledger`" `"$PostgresPassword`""
& kubectl create secret generic stayledger-pgbouncer-secret `
    --namespace=stayledger `
    --save-config `
    --dry-run=client `
    -o=yaml `
    "--from-literal=userlist.txt=$UserlistContent" `
    | kubectl apply -f -

if ($DocumentBackupS3AccessKeyId -ne "") {
    Write-Host "Creating stayledger-document-backup-s3..." -ForegroundColor Cyan
    & kubectl create secret generic stayledger-document-backup-s3 `
        --namespace=stayledger `
        --save-config `
        --dry-run=client `
        -o=yaml `
        "--from-literal=bucket=$DocumentBackupBucket" `
        "--from-literal=access-key-id=$DocumentBackupS3AccessKeyId" `
        "--from-literal=secret-access-key=$DocumentBackupS3SecretAccessKey" `
        "--from-literal=region=$DocumentBackupS3Region" `
        "--from-literal=encryption-passphrase=$DocumentBackupPassword" `
        | kubectl apply -f -
} else {
    Write-Host "Skipping stayledger-document-backup-s3 (no S3 credentials provided)." -ForegroundColor Yellow
    Write-Host "  Create it manually before enabling document backup CronJob:" -ForegroundColor Yellow
    Write-Host "  kubectl create secret generic stayledger-document-backup-s3 -n stayledger \\" -ForegroundColor Yellow
    Write-Host "    --from-literal=bucket=prd-stayledger-pms \\" -ForegroundColor Yellow
    Write-Host "    --from-literal=access-key-id=<key> \\" -ForegroundColor Yellow
    Write-Host "    --from-literal=secret-access-key=<secret> \\" -ForegroundColor Yellow
    Write-Host "    --from-literal=region=ap-southeast-1 \\" -ForegroundColor Yellow
    Write-Host "    --from-literal=encryption-passphrase='<same as DocumentBackupPassword>'" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Secrets created. Verify (no values shown):" -ForegroundColor Green
kubectl get secret stayledger-secrets -n stayledger
kubectl get secret stayledger-pgbouncer-secret -n stayledger
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Green
Write-Host "  1. kubectl apply -f stayledger-shared/datastores/production/storage.yaml"
Write-Host "  2. kubectl apply -f stayledger-shared/datastores/production/postgres.yaml"
Write-Host "  3. kubectl apply -f stayledger-shared/datastores/production/pgbouncer.yaml"
Write-Host "  4. kubectl apply -f stayledger-shared/datastores/production/redis.yaml"
Write-Host "  5. See stayledger-api/production/README.md for API deployment order"
