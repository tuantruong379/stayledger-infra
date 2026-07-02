# StayLedger API — Kubernetes Manifests

```text
k8s/
├── prd/                    # Production (namespace: stayledger)
│   ├── deployment.yaml     # ConfigMap + Deployment + Service (NodePort 30001)
│   └── migration-job.yaml  # Prisma migration Job template
└── staging/                # Staging (namespace: stayledger-staging)
    └── deployment.yaml     # ConfigMap + Deployment + Service + NodePort + Ingress + Migration Job
```

Infra prerequisites (postgres, redis, secrets) are in `stayledger-shared/k8s/prd/` or `staging/`.

## Deploy — Staging

```powershell
# Option A: automated script (recommended)
cd stayledger-api
.\scripts\deploy-staging.ps1

# Option B: manual (image built by CI on main as sha-<7-char>)
$SHORT = git rev-parse --short=7 HEAD
$TAG = "sha-$SHORT"
# Prefer the tag printed in the GitHub Actions workflow summary after merge to main.
docker pull putin111/stayledger-api:$TAG

(Get-Content k8s/staging/deployment.yaml) -replace "sha-PLACEHOLDER",$TAG | kubectl apply -f -
kubectl wait --for=condition=complete job/stayledger-db-migrate -n stayledger-staging --timeout=120s
kubectl rollout status deployment/stayledger-api -n stayledger-staging
```

## Deploy — Production

```powershell
$SHA = git rev-parse --short=8 HEAD
docker build -f Dockerfile -t putin111/stayledger-api:$SHA ..
docker push putin111/stayledger-api:$SHA

# Migration (delete old job first — jobs are immutable after completion)
kubectl delete job stayledger-db-migrate -n stayledger --ignore-not-found
(Get-Content k8s/prd/migration-job.yaml) -replace "<IMAGE_TAG>","$SHA" | kubectl apply -f -
kubectl wait --for=condition=complete job/stayledger-db-migrate -n stayledger --timeout=120s

# Rolling update
kubectl set image deployment/stayledger-api api=putin111/stayledger-api:$SHA -n stayledger
kubectl rollout status deployment/stayledger-api -n stayledger
```

## Health Checks

```bash
curl http://hkk8s-hub-master:30001/api/health    # production
curl https://stg-api.stayledger.io/api/health    # staging (ingress)
curl http://hkk8s-hub-master:30011/api/health    # staging (NodePort fallback)
```

## Rollback

```bash
kubectl rollout undo deployment/stayledger-api -n stayledger          # production
kubectl rollout undo deployment/stayledger-api -n stayledger-staging  # staging
```

### 1B.1 Decimal Read Rollback

The decimal read flip is env-only while Float columns remain in place. To roll
staging back without a deploy, patch the ConfigMap modes and restart the API:

```bash
kubectl patch configmap stayledger-api-config -n stayledger-staging --type merge -p "{\"data\":{\"PMS_MONEY_READ_MODE\":\"compare\",\"PMS_REPORT_MONEY_READ_MODE\":\"compare\",\"PMS_PRICING_MONEY_MODE\":\"compare\"}}"
kubectl rollout restart deployment/stayledger-api -n stayledger-staging
kubectl rollout status deployment/stayledger-api -n stayledger-staging
```

Use `float` for all three modes, or set `PMS_MONEY_PROD_READ_ENABLED=false`, for
the legacy Float-column read path. Do not drop Float columns during 1B.1.

## NodePorts

| Environment | NodePort | Ingress host (when configured)      |
|-------------|----------|-------------------------------------|
| Production  | 30001    | —                                   |
| Staging     | 30011    | stg-api.stayledger.io  |
