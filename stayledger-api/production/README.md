# stayledger-api — Production Deployment

Namespace: `stayledger` | Domain: `api.stayledger.io` | NodePort: `30001`

## First-time deployment order

```powershell
# 1. Namespace + secrets (run from stayledger-infra/ root)
kubectl apply -f stayledger-shared/datastores/production/namespace.yaml
.\stayledger-shared\datastores\production\generate-secrets.ps1 `
  -PostgresPassword "..." -JwtSecret "..." -JwtRefreshSecret "..." `
  -FrontendUrl "https://app.stayledger.io" `
  -AzureOpenAiEndpoint "https://..." -AzureOpenAiApiKey "..." `
  -ExternalSigningEncKey "$(openssl rand -hex 32)" `
  -EncryptionKey "$(openssl rand -hex 32)" `
  -DocumentBackupPassword "$(openssl rand -base64 48)" `
  -SmtpUser "..." -SmtpPassword "..."

# 2. Storage (create PVs + PVC)
kubectl apply -f stayledger-shared/datastores/production/storage.yaml
kubectl apply -f stayledger-api/production/guest-documents-pvc.yaml

# 3. Datastores
kubectl apply -f stayledger-shared/datastores/production/postgres.yaml
kubectl apply -f stayledger-shared/datastores/production/pgbouncer.yaml
kubectl apply -f stayledger-shared/datastores/production/redis.yaml

# 4. API — ServiceAccount must exist before migration Job
kubectl apply -f stayledger-api/production/serviceaccount.yaml

# 5. Run database migration (replace COMMIT_SHA with the 7-char short commit from CI)
export IMAGE_TAG=a1b2c3d
kubectl delete job stayledger-db-migrate -n stayledger --ignore-not-found
sed "s|COMMIT_SHA|${IMAGE_TAG}|g" stayledger-api/production/migration-job.yaml | kubectl apply -f -
kubectl wait --for=condition=complete job/stayledger-db-migrate -n stayledger --timeout=300s
kubectl logs job/stayledger-db-migrate -n stayledger

# 6. API workload
sed "s|COMMIT_SHA|${IMAGE_TAG}|g" stayledger-api/production/deployment.yaml | kubectl apply -f -
sed "s|COMMIT_SHA|${IMAGE_TAG}|g" stayledger-api/production/ai-worker-deployment.yaml | kubectl apply -f -
kubectl apply -f stayledger-api/production/configmap.yaml
kubectl apply -f stayledger-api/production/networkpolicy.yaml
kubectl apply -f stayledger-api/production/pdb.yaml
kubectl apply -f stayledger-api/production/hpa.yaml
kubectl rollout status deployment/stayledger-api -n stayledger
kubectl rollout status deployment/stayledger-ai-worker -n stayledger

# 7. Ingress (after DNS propagates)
kubectl apply -f stayledger-api/production/ingress.yaml

# 8. Observability
kubectl apply -f stayledger-api/production/ai-worker-servicemonitor.yaml
kubectl apply -f stayledger-shared/production/servicemonitor.yaml
kubectl apply -f stayledger-shared/production/prometheusrule.yaml

# 9. Backup CronJobs (after stayledger-document-backup-s3 secret exists)
kubectl apply -f stayledger-shared/datastores/production/postgres-backup-cronjob.yaml
kubectl apply -f stayledger-shared/datastores/production/postgres-backup-offnode-cronjob.yaml
kubectl apply -f stayledger-api/production/document-backup-offnode-cronjob.yaml
```

## Rolling update (new release)

```powershell
export IMAGE_TAG=a1b2c3d   # 7-char short commit from CI summary (no sha- prefix)

# Run migrations first
kubectl delete job stayledger-db-migrate -n stayledger --ignore-not-found
sed "s|COMMIT_SHA|${IMAGE_TAG}|g" stayledger-api/production/migration-job.yaml | kubectl apply -f -
kubectl wait --for=condition=complete job/stayledger-db-migrate -n stayledger --timeout=300s

# Update image in-place (avoids full re-apply)
kubectl set image deployment/stayledger-api api=putin111/stayledger-api:${IMAGE_TAG} -n stayledger
kubectl set image deployment/stayledger-ai-worker ai-worker=putin111/stayledger-api:${IMAGE_TAG} -n stayledger
kubectl rollout status deployment/stayledger-api -n stayledger
```

## Rollback

```powershell
kubectl rollout undo deployment/stayledger-api -n stayledger
kubectl rollout undo deployment/stayledger-ai-worker -n stayledger
```

## Post-deploy smoke checks

```bash
curl -fsS https://api.stayledger.io/api/ready          # 200 OK
curl -I   https://api.stayledger.io/api/docs            # 403 or 404 (SWAGGER_ENABLED=false)
curl -I -H "Origin: https://evil.example.com" https://api.stayledger.io/api/v1/auth/login
# Access-Control-Allow-Origin header must be absent
```
