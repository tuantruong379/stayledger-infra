# Production — stayledger k3s cluster

**Context:** `stayledger` | **Node:** `stayledger` @ `103.20.96.122` | **Ingress:** Traefik + cert-manager

**Full operator checklist:** [DEPLOYMENT-CHECKLIST.md](./DEPLOYMENT-CHECKLIST.md)

## Public URLs

| Product | URL | Namespace |
|---------|-----|-----------|
| PMS admin | `https://app.stayledger.io` | `stayledger` |
| PMS API | `https://api.stayledger.io` | `stayledger` |
| Marketing | `https://stayledger.io` | `stayledger` (already live) |
| AI admin + chat | `https://assistant.stayledger.io` | `stayledger-ai-assistant` |
| AI API | `https://api-assistant.stayledger.io` | `stayledger-ai-assistant` |

## Release images (staging-verified 2026-07-15)

| Workload | Image |
|----------|-------|
| PMS API + AI worker | `putin111/stayledger-api:f1b2e27` |
| PMS admin-web | `putin111/stayledger-admin-web:c4fadf3` |
| AI API + workers | `putin111/stayledger-ai-assistant:cvefix-e2a914e` (override via script) |
| AI frontend | `putin111/stayledger-ai-assistant-frontend:sha-golive1000712` (override via script) |

## Prerequisites

### 1. DNS (A records → `103.20.96.122`)

- `app.stayledger.io`
- `api.stayledger.io`
- `assistant.stayledger.io`
- `api-assistant.stayledger.io`

### 2. Node directories (SSH to stayledger node)

```bash
sudo mkdir -p /mnt/data/stayledger/{postgres,redis,guest-documents}
sudo mkdir -p /mnt/data/stayledger/ai-assistant/{postgres,postgres-backup,redis}
sudo chown -R 999:999 /mnt/data/stayledger/postgres /mnt/data/stayledger/redis
sudo chown -R 999:999 /mnt/data/stayledger/ai-assistant/postgres /mnt/data/stayledger/ai-assistant/postgres-backup /mnt/data/stayledger/ai-assistant/redis
sudo chown -R 1001:1001 /mnt/data/stayledger/guest-documents
```

### 3. PMS secrets (`stayledger-secrets`)

```powershell
.\stayledger-shared\datastores\production\generate-secrets.ps1 `
  -PostgresPassword "..." -JwtSecret "..." -JwtRefreshSecret "..." `
  -FrontendUrl "https://app.stayledger.io" `
  -AzureOpenAiEndpoint "https://..." -AzureOpenAiApiKey "..." `
  -ExternalSigningEncKey "$(openssl rand -hex 32)" `
  -EncryptionKey "$(openssl rand -hex 32)" `
  -DocumentBackupPassword "$(openssl rand -base64 48)" `
  -SmtpUser "..." -SmtpPassword "..."
```

### 4. AI assistant secrets (copy from `*.example.yaml`, gitignored)

- `base/datastores/redis-secret.yaml`
- `base/datastores/pgbouncer-secret.yaml`
- `base/app/hotel-assistant-api-secret.yaml`
- `base/app/hotel-assistant-smtp-secret.yaml`
- `base/app/hotel-assistant-frontend-secret.yaml`

## Deploy

```powershell
cd stayledger-infra
.\scripts\deploy-production-stayledger.ps1 -Phase preflight
.\scripts\deploy-production-stayledger.ps1 -Phase pms-datastores
.\scripts\deploy-production-stayledger.ps1 -Phase pms-app
.\scripts\deploy-production-stayledger.ps1 -Phase ai-assistant
.\scripts\deploy-production-stayledger.ps1 -Phase ingress
# Or all at once (after secrets + DNS):
.\scripts\deploy-production-stayledger.ps1 -Phase all
```

## Post-deploy verification

```powershell
# PMS
curl -fsS https://api.stayledger.io/api/health
curl -fsS https://app.stayledger.io/healthz

# AI assistant
curl -fsS https://api-assistant.stayledger.io/health
curl -fsS https://assistant.stayledger.io/

# E2E (from stayledger-e2e, after .env.production)
pnpm verify:golive
```

## Rollback

```powershell
kubectl --context stayledger rollout undo deployment/stayledger-api -n stayledger
kubectl --context stayledger rollout undo deployment/stayledger-admin-web -n stayledger
kubectl --context stayledger rollout undo deployment/hotel-assistant-api -n stayledger-ai-assistant
```
