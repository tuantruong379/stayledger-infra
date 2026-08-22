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

    # Deprecated — Nest never reads ENCRYPTION_KEY (use ExternalSigningEncKey).
    # Kept optional so older runbooks that still pass -EncryptionKey do not break.
    [string]$EncryptionKey = "",

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
    [string]$DocumentBackupS3Region = "ap-southeast-1",

    # Optional PgBouncer stats user password for prometheus-pgbouncer-exporter (OBS-03).
    # If omitted, a random password is generated for new installs.
    [string]$PgBouncerExporterPassword = ""
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
if ($EncryptionKey -ne "") {
    Write-Warning "EncryptionKey is ignored — Nest uses EXTERNAL_SIGNING_ENC_KEY only (encryption-key is not written)."
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
    "--from-literal=external-signing-enc-key=$ExternalSigningEncKey",
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
if ([string]::IsNullOrWhiteSpace($PgBouncerExporterPassword)) {
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $PgBouncerExporterPassword = [Convert]::ToBase64String($bytes)
}
$UserlistContent = "`"stayledger`" `"$PostgresPassword`"`n`"pgbouncer_exporter`" `"$PgBouncerExporterPassword`""
& kubectl create secret generic stayledger-pgbouncer-secret `
    --namespace=stayledger `
    --save-config `
    --dry-run=client `
    -o=yaml `
    "--from-literal=userlist.txt=$UserlistContent" `
    | kubectl apply -f -

Write-Host "Creating observability/pgbouncer-exporter-config..." -ForegroundColor Cyan
$obsNs = kubectl get namespace observability -o name 2>$null
if (-not $obsNs) {
    Write-Host "  Skipping pgbouncer-exporter-config (observability namespace not found). Create it during observability install." -ForegroundColor Yellow
} else {
    $PgEnc = [Uri]::EscapeDataString($PgBouncerExporterPassword)
    $PgBouncerExporterConfig = @"
exporter_host: 0.0.0.0
exporter_port: 9127
pgbouncers:
  - dsn: postgresql://pgbouncer_exporter:${PgEnc}@stayledger-pgbouncer.stayledger.svc.cluster.local:5432/pgbouncer
    connect_timeout: 5
    exclude_databases:
      - pgbouncer
"@
    & kubectl create secret generic pgbouncer-exporter-config `
        --namespace=observability `
        --save-config `
        --dry-run=client `
        -o=yaml `
        "--from-literal=config.yml=$PgBouncerExporterConfig" `
        | kubectl apply -f -
}

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
