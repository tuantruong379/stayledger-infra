# StayLedger API — Kubernetes Manifests

```text
stayledger-api/
├── base/           # Shared manifests (Kustomize)
├── staging/        # Staging overlay — kubectl apply -k staging/
├── production/     # Production overlay — kubectl apply -k production/
└── prd/            # DEPRECATED stubs
```

Datastores: `stayledger-shared/datastores/{staging,production}/`

## Deploy — Staging

```powershell
kubectl apply -k stayledger-api/staging/
kubectl apply -f stayledger-api/base/migration-job.yaml -n stayledger-staging  # one-shot, when needed
kubectl rollout status deployment/stayledger-api -n stayledger-staging
```

Verified image tags (2026-07-04): `staging-b29e645` (API/AI worker), set in `staging/kustomization.yaml`.

## Deploy — Production

See [production/README.md](production/README.md) and `kubectl apply -k stayledger-api/production/`.

## Health Checks

```bash
curl https://stg-api.stayledger.io/api/ready    # staging
curl http://hkk8s-hub-master:30011/api/ready    # staging NodePort
curl https://api.stayledger.io/api/ready        # production
```

## Rollback

```bash
kubectl rollout undo deployment/stayledger-api -n stayledger-staging
kubectl rollout undo deployment/stayledger-api -n stayledger
```
