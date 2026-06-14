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

# Option B: manual
$SHA = git rev-parse --short=8 HEAD
docker build -f Dockerfile -t putin111/stayledger-api:staging-$SHA ..
docker push putin111/stayledger-api:staging-$SHA

(Get-Content k8s/staging/deployment.yaml) -replace "staging-PLACEHOLDER","staging-$SHA" | kubectl apply -f -
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
curl http://hkk8s-hub-master:30011/api/health    # staging
```

## Rollback

```bash
kubectl rollout undo deployment/stayledger-api -n stayledger          # production
kubectl rollout undo deployment/stayledger-api -n stayledger-staging  # staging
```

## NodePorts

| Environment | NodePort | Ingress host (when configured)      |
|-------------|----------|-------------------------------------|
| Production  | 30001    | —                                   |
| Staging     | 30011    | api-staging.stayledger.tekcent.com  |
