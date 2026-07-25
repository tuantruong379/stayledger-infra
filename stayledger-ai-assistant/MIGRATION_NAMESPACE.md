# Namespace migration: `hotel-assistant` → `stayledger-ai-assistant`

**Status (2026-07-15):** Staging cutover is **complete**. The live HK-HUB cluster runs in
`stayledger-ai-assistant`; the old `hotel-assistant` namespace is gone.

Manifests in this repo target **`stayledger-ai-assistant`**. ServiceMonitors and Prometheus
storage (25Gi claim matching PV) match what is deployed in staging.

## Naming convention (current)

| Layer | Value | Notes |
| --- | --- | --- |
| Kubernetes namespace | `stayledger-ai-assistant` | Matches repo / image naming |
| `app.kubernetes.io/part-of` label | `stayledger-ai-assistant` | All workloads |
| Deployment / Service names | `hotel-assistant-*` | Unchanged for now — rename in a later phase |
| Host PV paths | `/mnt/hotel-assistant/*` | Unchanged — filesystem paths are independent of namespace |
| Docker images | `putin111/stayledger-ai-assistant` | Already standardized |

Deploy with:

```powershell
kubectl apply -k stayledger-ai-assistant/staging/
kubectl rollout restart deployment/hotel-assistant-frontend deployment/hotel-assistant-api -n stayledger-ai-assistant
```

Staging is **NodePort only** (no ingress). Public URLs: `stg-assistant.stayledger.io` (30081),
`stg-api-assistant.stayledger.io` (30080).

All `kubectl` examples use `-n stayledger-ai-assistant`.

---

## Pre-cutover checklist

- [ ] Merge manifest PR (this repo + `stayledger-ai-assistant` Makefile/docs)
- [ ] Confirm PV reclaim policy is `Retain`: `kubectl get pv postgres-pv redis-pv`
- [ ] Export secrets from old namespace (or have secret YAML files ready)
- [ ] Schedule a **15–30 minute** maintenance window
- [ ] Notify users (admin UI + API will be briefly unavailable)

```powershell
kubectl get all,pvc,pv,ingress -n hotel-assistant -o wide
kubectl exec -n hotel-assistant deploy/postgres -- \
  pg_dump -U hotelassistant -Fc hotel_ops > hotel_ops_pre_migration.dump
```

---

## Cutover steps (staging)

### 1. Scale down app tier

```powershell
kubectl scale deployment -n hotel-assistant `
  hotel-assistant-api,hotel-assistant-frontend,`
  hotel-assistant-channel-worker,hotel-assistant-webhook-worker,`
  hotel-assistant-metrics-aggregator --replicas=0
```

### 2. Stop datastores and release PVCs

```powershell
kubectl scale deployment -n hotel-assistant postgres redis --replicas=0
kubectl wait --for=delete pod -n hotel-assistant -l app.kubernetes.io/name=postgres --timeout=120s

# PVCs use explicit volumeName — PVs are retained. Clear stale claimRef if re-migrating:
#   kubectl patch pv postgres-pv redis-pv postgres-backup-pv -p '{"spec":{"claimRef":null}}'
kubectl delete pvc postgres-data redis-data postgres-backup -n hotel-assistant
```

### 3. Deploy into new namespace

```powershell
# Secrets first (update namespace in YAML or pipe through sed)
kubectl apply -f stayledger-ai-assistant/base/datastores/redis-secret.yaml
kubectl apply -f stayledger-ai-assistant/base/datastores/pgbouncer-secret.yaml
kubectl apply -f stayledger-ai-assistant/base/app/hotel-assistant-api-secret.yaml
kubectl apply -f stayledger-ai-assistant/base/app/hotel-assistant-smtp-secret.yaml
kubectl apply -f stayledger-ai-assistant/base/app/hotel-assistant-frontend-secret.yaml

kubectl apply -k stayledger-ai-assistant/staging/
kubectl rollout restart deployment/hotel-assistant-frontend deployment/hotel-assistant-api -n stayledger-ai-assistant
```

### 4. Verify PVC rebind

```powershell
kubectl get pvc -n stayledger-ai-assistant
# postgres-data → postgres-pv, redis-data → redis-pv
```

### 5. Run migrations and wait for rollouts

```powershell
# From stayledger-ai-assistant repo:
make migrate IMAGE=putin111/stayledger-ai-assistant:<tag>

kubectl rollout status deployment/hotel-assistant-api -n stayledger-ai-assistant --timeout=300s
kubectl rollout status deployment/hotel-assistant-frontend -n stayledger-ai-assistant --timeout=300s
```

### 6. Health checks

```powershell
kubectl exec -n stayledger-ai-assistant deploy/hotel-assistant-api -- curl -fsS http://127.0.0.1:8000/health
kubectl exec -n stayledger-ai-assistant deploy/hotel-assistant-api -- curl -fsS http://127.0.0.1:8000/readyz

curl -fsS https://stg-api-assistant.stayledger.io/health
curl -fsS https://stg-assistant.stayledger.io/
```

### 7. Observability

```powershell
kubectl apply -k stayledger-ai-assistant/observability/
# Confirm Prometheus targets scrape stayledger-ai-assistant namespace
```

### 8. Cleanup (after 24–48h soak)

```powershell
kubectl delete namespace hotel-assistant
```

---

## Rollback

If cutover fails **before** deleting `hotel-assistant`:

1. Scale down workloads in `stayledger-ai-assistant`
2. Delete PVCs in `stayledger-ai-assistant`
3. Recreate PVCs in `hotel-assistant` with the same `volumeName:` bindings
4. Scale postgres/redis and app deployments back up in `hotel-assistant`

---

## Copying secrets without editing files

```powershell
$secrets = @(
  'hotel-assistant-api-secrets',
  'hotel-assistant-smtp-secrets',
  'hotel-assistant-frontend-secrets',
  'redis-secret',
  'pgbouncer-secret'
)
foreach ($s in $secrets) {
  kubectl get secret $s -n hotel-assistant -o yaml |
    ForEach-Object { $_ -replace 'namespace: hotel-assistant','namespace: stayledger-ai-assistant' } |
    ForEach-Object { $_ -replace '^\s*resourceVersion:.*','' } |
    ForEach-Object { $_ -replace '^\s*uid:.*','' } |
    kubectl apply -f -
}
```

---

## Phase 2 (optional, later)

- Rename workloads `hotel-assistant-api` → `stayledger-ai-assistant-api`
- Rename host paths `/mnt/hotel-assistant/*` → `/mnt/stayledger-ai-assistant/*`
- Remove `argocd/` references if GitOps is adopted later
