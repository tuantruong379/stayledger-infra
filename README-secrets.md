# StayLedger Kubernetes Secrets

**Strategy (Release 2):** Operator-generated secrets applied via `kubectl` — **no plaintext in git**.

Future: SealedSecrets or SOPS (documented below, not yet installed).

## Required Secrets

### API / AI worker (`stayledger-staging-secrets` / `stayledger-secrets`)

| Key | Purpose |
|-----|---------|
| `DATABASE_URL` | PgBouncer pooled connection |
| `DIRECT_DATABASE_URL` | Direct Postgres (migrations only) |
| `REDIS_URL` | Redis connection |
| `JWT_SECRET` | Access token signing |
| `JWT_REFRESH_SECRET` | Refresh token signing |
| `CSRF_SECRET` | CSRF protection |
| `ENCRYPTION_KEY` | General encryption |
| `DOCUMENT_ENCRYPTION_KEY` | Guest document encryption |
| `DOCUMENT_BACKUP_PASSWORD` | Backup archive passphrase |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | S3 DR backup |
| `SES_SMTP_USERNAME` / `SES_SMTP_PASSWORD` | Email (keys: `smtp-user`, `smtp-password`) |
| `METRICS_AUTH_TOKEN` | Prometheus scrape auth |
| `AZURE_OPENAI_API_KEY` / `AZURE_OPENAI_ENDPOINT` | AI provider |

### Additional secrets

| Secret | Environment | Template |
|--------|-------------|----------|
| `stayledger-pgbouncer-secret` | staging/production | `datastores/*/pgbouncer-secret.example.yaml` |
| `backup-offnode-s3` | staging/production | `datastores/*/backup-offnode-s3-secret.example.yaml` |
| `stayledger-document-backup-s3` | staging/production | Applied via backup CronJob setup |

## Generate and Apply

### Staging metrics auth (post security review)

```powershell
.\stayledger-infra\scripts\configure-staging-metrics-auth.ps1
# Verify: curl -sk -o NUL -w "%{http_code}" https://stg-api.stayledger.io/api/metrics  → 401
```

### Staging RBAC fixture repair

```powershell
.\stayledger-infra\scripts\repair-staging-rbac-fixtures.ps1
```

### Staging secrets bootstrap

```powershell
cd stayledger-infra/stayledger-shared/datastores/staging
.\generate-secrets.ps1 `
  -PostgresPassword "<strong>" `
  -JwtSecret "<64+ chars>" `
  -JwtRefreshSecret "<64+ chars>" `
  -FrontendUrl "https://stg-app.stayledger.io" `
  -AzureOpenAiEndpoint "https://<resource>.cognitiveservices.azure.com" `
  -AzureOpenAiApiKey "<key>"
```

### Production

```powershell
cd stayledger-infra/stayledger-shared/datastores/production
.\generate-secrets.ps1 -FrontendUrl "https://app.stayledger.io" ...
```

**Production must use newly generated secrets** — never copy staging values.

## Templates

| File | Purpose |
|------|---------|
| `stayledger-api/staging/secret.template.yaml` | Staging key inventory |
| `stayledger-api/staging/secret.example.yaml` | Placeholder values (`__SECRET_REF:*`) |
| `stayledger-api/production/secret.template.yaml` | Production key inventory |

Copy `secret.example.yaml` → `secret.yaml` (gitignored), fill values, apply locally.

## Security Rules

1. Never commit `secret.yaml`, `*-secret.yaml`, or real credentials
2. Rotate staging credentials before production launch if they were ever in git history
3. Use `__SECRET_REF:*` in docs and E2E preflight — never print values
4. Verify secrets are referenced: `kubectl get deploy stayledger-api -o yaml | grep secretKeyRef`

## Future: SealedSecrets / SOPS

Recommended post-launch:

- **SealedSecrets:** Encrypt secrets for git storage; cluster controller decrypts on apply
- **SOPS + age:** Encrypt YAML in repo; decrypt in CI/CD with age key

Until then, secrets live only on the cluster and in the operator password manager.

## Inventories

- [docs/infra/staging-secret-inventory.md](../../docs/infra/staging-secret-inventory.md)
- [docs/infra/production-secret-inventory.md](../../docs/infra/production-secret-inventory.md)
