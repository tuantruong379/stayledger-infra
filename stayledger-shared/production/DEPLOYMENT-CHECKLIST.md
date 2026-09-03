# StayLedger Production Deployment Checklist

**Cluster:** `stayledger` (k3s) @ `103.20.96.122`  
**Ingress:** Traefik + cert-manager (`letsencrypt-prod`)  
**Services:** ClusterIP only (no NodePort for public apps)  
**Release images (staging-verified 2026-08-22):**

| Workload | Image |
|----------|-------|
| PMS API + AI worker | `putin111/stayledger-api@sha256:109c699e…` (tag `6764d49`, release/1.3.5) |
| PMS admin-web | `putin111/stayledger-admin-web@sha256:442b5279…` (tag `77cebd3`, release/1.3.10) |
| PMS landing | `putin111/stayledger-landing@sha256:468a133c…` (tag `de9c838`, release/1.1.6) |
| AI API + workers | `putin111/ai-hotel-assistant:<tag>` |
| AI frontend | `putin111/ai-hotel-assistant-frontend:<tag>` |

**Drift audit:** `.\scripts\audit-production-drift.ps1` (compare live cluster vs git manifests).

**Operator:** _______________  **Date:** _______________  **GO / NO-GO:** _______________

---

## Architecture rules (must stay true)

- [ ] Public apps use **ClusterIP** Services only (no NodePort)
- [ ] Public HTTPS only via **Traefik Ingress** + **cert-manager**
- [ ] Issuer: `letsencrypt-prod`
- [ ] DNS A records point to Traefik LB: `103.20.96.122`

| Host | Namespace | Service | Port | TLS secret |
|------|-----------|---------|------|------------|
| `app.stayledger.io` | `stayledger` | `stayledger-admin-web` | 80 | `stayledger-production-app-tls` |
| `api.stayledger.io` | `stayledger` | `stayledger-api` | 80 | `stayledger-production-api-tls` |
| `assistant.stayledger.io` | `stayledger-ai-assistant` | `hotel-assistant-frontend` | 3000 | `stayledger-ai-assistant-frontend-tls` |
| `api-assistant.stayledger.io` | `stayledger-ai-assistant` | `hotel-assistant-api` | 8000 | `stayledger-ai-assistant-api-tls` |
| `stayledger.io` / `www` | `stayledger` | `stayledger-landing` | 80 | `stayledger-landing-tls` (already live) |

---

## Phase 0 — Preflight

### 0.1 Staging gate (already done for this promote)

- [x] Staging API `f1b2e27` healthy
- [x] Staging admin-web `c4fadf3` healthy
- [x] `pnpm verify:golive` PASS (14/14)
- [x] Staging phase pack PASS (retry after 429 cooldown OK)

### 0.2 Cluster / tools

- [ ] `kubectl config use-context stayledger`
- [ ] Node Ready: `kubectl get nodes -o wide` → hostname `stayledger`
- [ ] `cert-manager` Running
- [ ] `ClusterIssuer/letsencrypt-prod` Ready
- [ ] Docker Hub can pull release images (no auth failure on deploy)

```powershell
.\scripts\deploy-production-stayledger.ps1 -Phase preflight
```

### 0.3 DNS (block ingress/TLS until green)

- [ ] `app.stayledger.io` → `103.20.96.122`
- [ ] `api.stayledger.io` → `103.20.96.122`
- [ ] `assistant.stayledger.io` → `103.20.96.122`
- [ ] `api-assistant.stayledger.io` → `103.20.96.122`
- [ ] Cloudflare / edge: ACME HTTP-01 path reachable (`/.well-known/acme-challenge/*`)  
      Prefer DNS-01 later if Always Use HTTPS must stay on.

### 0.4 Node host paths (SSH to node)

```bash
sudo mkdir -p /mnt/data/stayledger/{postgres,redis,guest-documents}
sudo mkdir -p /mnt/data/stayledger/ai-assistant/{postgres,postgres-backup,redis}
sudo chown -R 999:999 /mnt/data/stayledger/postgres /mnt/data/stayledger/redis
sudo chown -R 999:999 /mnt/data/stayledger/ai-assistant/{postgres,postgres-backup,redis}
sudo chown -R 1001:1001 /mnt/data/stayledger/guest-documents
```

- [ ] PMS postgres/redis/guest-documents dirs exist + ownership correct
- [ ] AI assistant postgres/redis/backup dirs exist + ownership correct

---

## Phase 1 — Secrets & config (do not commit values)

### 1.1 PMS — `stayledger-secrets`

```powershell
.\stayledger-shared\datastores\production\generate-secrets.ps1 `
  -PostgresPassword "..." `
  -JwtSecret "..." `          # >= 64 chars
  -JwtRefreshSecret "..." `   # >= 64 chars
  -FrontendUrl "https://app.stayledger.io" `
  -AzureOpenAiEndpoint "https://..." `
  -AzureOpenAiApiKey "..." `
  -ExternalSigningEncKey "$(openssl rand -hex 32)" `
  -DocumentBackupPassword "$(openssl rand -base64 48)" `
  -SmtpUser "..." -SmtpPassword "..."
```

- [ ] `kubectl get secret stayledger-secrets -n stayledger`
- [ ] Keys present: `database-url`, `direct-database-url`, `jwt-secret`, `jwt-refresh-secret`, `external-signing-enc-key`, Azure, SMTP
- [ ] Optional: `stayledger-document-backup-s3` created (bucket + keys + passphrase)
- [ ] SES production identity/domain verified (`noreply@stayledger.io` or agreed From)

### 1.2 PMS ConfigMap checks

- [ ] `NODE_ENV=production`, `APP_ENV=production`
- [ ] `SWAGGER_ENABLED=false`
- [ ] `ALLOWED_ORIGINS` / CORS includes `https://app.stayledger.io` and marketing origins as needed
- [ ] `DOCUMENT_CAPTURE_DEFAULT_ENABLED=false` (opt-in per property)
- [ ] `FEATURE_DOCUMENT_OCR=false` (until OCR go-live)
- [ ] Admin-web `AI_ASSISTANT_INTERNAL_API_URL=https://api-assistant.stayledger.io`

### 1.3 AI Assistant secrets (gitignored files)

Copy from `*.example.yaml` and apply locally:

- [ ] `base/datastores/redis-secret.yaml`
- [ ] `base/datastores/pgbouncer-secret.yaml`
- [ ] `base/app/hotel-assistant-api-secret.yaml`
- [ ] `base/app/hotel-assistant-smtp-secret.yaml`
- [ ] `base/app/hotel-assistant-frontend-secret.yaml`
- [ ] Production CORS includes `https://assistant.stayledger.io` (+ `https://app.stayledger.io` if needed)

---

## Phase 2 — PMS datastores

```powershell
.\scripts\deploy-production-stayledger.ps1 -Phase pms-datastores
```

- [ ] StorageClass `local-storage-stayledger` created
- [ ] PVs Bound: postgres, redis, guest-documents
- [ ] PVC Bound: `stayledger-postgres-pvc`, `stayledger-redis-pvc`, `stayledger-guest-documents`
- [ ] Postgres StatefulSet Ready
- [ ] PgBouncer Ready
- [ ] Redis Ready

```powershell
kubectl --context stayledger get pv,pvc,pod -n stayledger
kubectl --context stayledger rollout status statefulset/stayledger-postgres -n stayledger
```

---

## Phase 3 — PMS application

```powershell
.\scripts\deploy-production-stayledger.ps1 -Phase pms-app
```

- [ ] Job `stayledger-db-migrate` Completed (`prisma migrate deploy` PASS)
- [ ] Deployment `stayledger-api` Ready (image `f1b2e27`) — replicas=1 for RWO guest docs
- [ ] Deployment `stayledger-ai-worker` Ready
- [ ] Deployment `stayledger-admin-web` Ready (image `c4fadf3`)
- [ ] Service types are **ClusterIP** (no `stayledger-api-nodeport` / no NodePort on admin-web)
- [ ] In-cluster health OK (port-forward if needed before DNS):

```powershell
kubectl --context stayledger -n stayledger port-forward svc/stayledger-api 18080:80
# then: curl http://127.0.0.1:18080/api/health
```

- [ ] Audited minimal seed only (no E2E demo passwords on production) — if seeding
- [ ] SUPER_ADMIN bootstrap account recorded in password manager

---

## Phase 4 — AI Assistant

```powershell
.\scripts\deploy-production-stayledger.ps1 -Phase ai-assistant `
  -AiApiTag <tag> -AiFrontendTag <tag>
```

- [ ] Namespace `stayledger-ai-assistant` exists
- [ ] AI postgres / redis / pgbouncer / nats Ready
- [ ] One-time bootstrap job considered / applied if fresh DB  
  `kubectl apply -f stayledger-ai-assistant-api/base/datastores/postgres-bootstrap-job.yaml`
- [ ] Job `alembic-upgrade` Completed
- [ ] Deployments Ready: `hotel-assistant-api`, `hotel-assistant-frontend`, workers
- [ ] Services **ClusterIP** only (`hotel-assistant-api`, `hotel-assistant-frontend`)
- [ ] In-cluster health:

```powershell
kubectl --context stayledger -n stayledger-ai-assistant exec deploy/hotel-assistant-api -- curl -fsS http://127.0.0.1:8000/health
kubectl --context stayledger -n stayledger-ai-assistant exec deploy/hotel-assistant-api -- curl -fsS http://127.0.0.1:8000/readyz
```

---

## Phase 5 — Ingress + TLS

> Run only after DNS propagates.

```powershell
.\scripts\deploy-production-stayledger.ps1 -Phase ingress
```

- [ ] Ingress objects present (Traefik class):
  - `stayledger-api`, `stayledger-admin-web`
  - `hotel-assistant-api`, `hotel-assistant-frontend`
- [ ] Certificates Ready:

```powershell
kubectl --context stayledger get certificate -A
kubectl --context stayledger describe certificate stayledger-production-api-tls -n stayledger
kubectl --context stayledger describe certificate stayledger-production-app-tls -n stayledger
```

- [ ] HTTPS smoke:

```bash
curl -fsS https://api.stayledger.io/api/health
curl -fsS https://api.stayledger.io/api/ready
curl -fsS https://app.stayledger.io/healthz
curl -fsS https://api-assistant.stayledger.io/health
curl -fsS https://assistant.stayledger.io/
```

- [ ] Swagger blocked: `https://api.stayledger.io/api/docs` → not public OpenAPI
- [ ] CORS reject: Origin `https://evil.example.com` has no `Access-Control-Allow-Origin`

---

## Phase 6 — Post-deploy verification

### 6.1 Workload health

- [ ] `kubectl get deploy,sts,pod,svc,ingress -n stayledger`
- [ ] `kubectl get deploy,pod,svc,ingress -n stayledger-ai-assistant`
- [ ] No CrashLoopBackOff / ImagePullBackOff
- [ ] Landing still healthy: `https://stayledger.io`

### 6.2 Functional smoke (PMS)

- [ ] Login page loads (`https://app.stayledger.io/login`)
- [ ] Authenticated SUPER_ADMIN can open dashboard
- [ ] Create/read one booking smoke (or property template import) as agreed
- [ ] Guest document feature stays opt-in off by default
- [ ] Metrics endpoint protected (`/api/metrics` → 401 without token)

### 6.3 Functional smoke (AI)

- [ ] Admin UI loads (`https://assistant.stayledger.io`)
- [ ] API health/ready green
- [ ] Auth login works
- [ ] One tenant chat / health path smoke

### 6.4 Backups (before marking GO)

- [ ] Postgres backup CronJob applied / scheduled
- [ ] Guest-document off-node backup CronJob applied (if S3 secret ready)
- [ ] Optional restore drill scheduled within 7 days of go-live

### 6.5 Full gate (when credentials ready)

- [ ] Production `.env` for e2e prepared (never commit)
- [ ] `pnpm verify:golive` against production URLs (or agreed subset) PASS
- [ ] Optional: k6 smoke / baseline PASS

---

## Phase 7 — Go-live decision

| Gate | PASS? | Evidence |
|------|-------|----------|
| DNS + TLS Ready for all 4 hosts | | |
| PMS migrate + API/admin Ready | | |
| AI alembic + API/frontend Ready | | |
| ClusterIP only (no public NodePort) | | |
| Traefik Ingress + HTTPS smokes | | |
| Secrets not in git | | |
| SES / Azure OpenAI production credentials | | |
| Backup jobs configured | | |
| Rollback owner named | | |

**Production GO requires every P0 row above checked.**  
Staging PASS alone is not production GO.

### Rollback (if needed)

```powershell
kubectl --context stayledger rollout undo deployment/stayledger-api -n stayledger
kubectl --context stayledger rollout undo deployment/stayledger-ai-worker -n stayledger
kubectl --context stayledger rollout undo deployment/stayledger-admin-web -n stayledger
kubectl --context stayledger rollout undo deployment/hotel-assistant-api -n stayledger-ai-assistant
kubectl --context stayledger rollout undo deployment/hotel-assistant-frontend -n stayledger-ai-assistant
```

---

## Quick deploy script map

| Phase | Command |
|-------|---------|
| Preflight | `.\scripts\deploy-production-stayledger.ps1 -Phase preflight` |
| PMS datastores | `.\scripts\deploy-production-stayledger.ps1 -Phase pms-datastores` |
| PMS apps | `.\scripts\deploy-production-stayledger.ps1 -Phase pms-app` |
| AI assistant | `.\scripts\deploy-production-stayledger.ps1 -Phase ai-assistant` |
| Ingress/TLS | `.\scripts\deploy-production-stayledger.ps1 -Phase ingress` |
| All (after secrets + DNS) | `.\scripts\deploy-production-stayledger.ps1 -Phase all` |

## Related docs

- [production/README.md](./README.md) — URLs, images, quick commands
- [stayledger-api/production/README.md](../../stayledger-api/production/README.md) — PMS first-time order
- [docs/infra/production-values-to-change.md](../../../docs/infra/production-values-to-change.md) — staging → prod value matrix
- [docs/reviews/stayledger-pms-production-golive-checklist.md](../../../docs/reviews/stayledger-pms-production-golive-checklist.md) — broader product/security GO gates
