# StayLedger Admin Web — Kubernetes Manifests

```text
k8s/
├── prd/                 # Production (namespace: stayledger)
│   └── deployment.yaml  # ConfigMap + Deployment + Service (NodePort 30000)
└── staging/             # Staging (namespace: stayledger-staging)
    └── deployment.yaml  # ConfigMap + Deployment + Service + NodePort + Ingress
```

Infra prerequisites (postgres, redis, secrets) are in `stayledger-shared/k8s/prd/` or `staging/`.

> **Note:** `NEXT_PUBLIC_*` vars are baked at image build time via `--build-arg`. The ConfigMap
> in each `deployment.yaml` documents the expected values — they are not injected at runtime.

## Deploy — Staging

```powershell
# Option A: automated script (recommended)
cd stayledger-admin-web
.\scripts\deploy-staging.ps1

# Option B: manual (image built by CI on main as <7-char> short commit, no sha- prefix)
$TAG = git rev-parse --short=7 HEAD
# Prefer the tag printed in the GitHub Actions workflow summary after merge to main.
docker pull putin111/stayledger-admin-web:$TAG

(Get-Content k8s/staging/deployment.yaml) -replace "COMMIT_SHA",$TAG | kubectl apply -f -
kubectl rollout status deployment/stayledger-admin-web -n stayledger-staging
```

## Deploy — Production

```powershell
$SHA = git rev-parse --short=8 HEAD
docker build `
  --build-arg NEXT_PUBLIC_API_URL=https://stayledger.tekcent.com/api `
  --build-arg NEXT_PUBLIC_APP_ENV=production `
  -t putin111/stayledger-admin-web:$SHA .
docker push putin111/stayledger-admin-web:$SHA

kubectl set image deployment/stayledger-admin-web admin-web=putin111/stayledger-admin-web:$SHA -n stayledger
kubectl rollout status deployment/stayledger-admin-web -n stayledger
```

## Health Checks

```bash
curl http://hkk8s-hub-master:30000/healthz    # production
curl https://stg-app.stayledger.io/healthz    # staging (ingress)
curl http://hkk8s-hub-master:30010/healthz    # staging (NodePort fallback)
```

## Rollback

```bash
kubectl rollout undo deployment/stayledger-admin-web -n stayledger          # production
kubectl rollout undo deployment/stayledger-admin-web -n stayledger-staging  # staging
```

## NodePorts

| Environment | NodePort | Ingress host (when configured)            |
|-------------|----------|-------------------------------------------|
| Production  | 30000    | —                                         |
| Staging     | 30010    | stg-app.stayledger.io      |
