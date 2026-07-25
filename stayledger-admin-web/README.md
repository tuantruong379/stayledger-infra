# StayLedger Admin Web — Kubernetes Manifests

```text
stayledger-admin-web/
├── base/                 # Deployment + Service + HPA + ServiceAccount (kustomize base)
├── staging/              # Staging overlay (namespace: stayledger-staging, NodePort 30010)
│   ├── kustomization.yaml
│   ├── configmap.yaml
│   └── patches/
└── production/           # Production overlay (namespace: stayledger, ClusterIP + Ingress)
    ├── kustomization.yaml
    ├── configmap.yaml
    └── patches/
```

Infra prerequisites (postgres, redis, secrets) live in `stayledger-shared/datastores/`.

> **Note:** `NEXT_PUBLIC_API_URL` and `NEXT_PUBLIC_BOOKING_WEB_URL` are baked as **placeholder**
> URLs at image build time, then rewritten at pod start by the `env-inject` init container using
> the ConfigMap values. The same image therefore works across staging and production without a
> rebuild. Other `NEXT_PUBLIC_*` feature flags are inlined at build time.

---

## ⚠️ CRITICAL — the `env-inject` init container serves the bundle

This Deployment runs **two containers off the SAME image**, bound by the `&adminWebImage`
YAML anchor in `base/deployment.yaml`:

- **`env-inject` (initContainer)** — copies **its own** `/app/.next` into the shared `next-patched`
  emptyDir, then rewrites the placeholder URLs.
- **`admin-web` (main container)** — **mounts `next-patched` over its own `/app/.next`** and serves it.

Because the main container serves the volume populated by the init container, **the `env-inject`
image is the one that actually determines the JS/HTML being served.** If the two images drift, the
init container overwrites the new build with stale assets and:

> **the pod reports the new tag but serves OLD JS.** No error, no crash — silently stale UI.

### The trap (do NOT do this)

```powershell
# ❌ WRONG — only updates the MAIN container. env-inject keeps the old image and
#    overwrites /app/.next with the OLD bundle. Pod says new tag, serves old UI.
kubectl set image deployment/stayledger-admin-web admin-web=putin111/stayledger-admin-web:$TAG -n stayledger-staging
```

Symptom seen in the wild: cluster shows the new tag and a new image digest, but inside the pod
`/app/.next/BUILD_ID` and the JS chunks are from a much older image. Rebuilding, `--no-cache`,
single-arch images, and browser hard-refresh all fail to fix it — because the root cause is the
init container, not the build or the cache.

---

## Deploy — Staging (namespace `stayledger-staging`, context `HK-HUB-Cluster`)

**Always deploy via kustomize.** The `images:` transformer in `kustomization.yaml` matches by image
**name**, so it updates **both** `env-inject` and `admin-web` in lockstep — this is the only method
that cannot drift.

```powershell
kubectl config use-context HK-HUB-Cluster   # staging cluster (see .cursor rules)

# 1. Point the overlay at the new tag (7-char commit from CI, or a manual staging-* tag)
#    Edit stayledger-admin-web/staging/kustomization.yaml -> images[].newTag

# 2. Apply — updates BOTH containers
kubectl apply -k stayledger-admin-web/staging/
kubectl rollout status deployment/stayledger-admin-web -n stayledger-staging
```

### Emergency `kubectl set image` (only if you cannot apply -k)

Set **both** containers, or you will hit the trap above:

```powershell
$IMG = "putin111/stayledger-admin-web:$TAG"
kubectl set image deployment/stayledger-admin-web `
  env-inject=$IMG `
  admin-web=$IMG `
  -n stayledger-staging
kubectl rollout status deployment/stayledger-admin-web -n stayledger-staging
```

---

## Deploy — Production (namespace `stayledger`, context `stayledger`)

```powershell
kubectl config use-context stayledger        # production cluster

# Edit stayledger-admin-web/production/kustomization.yaml -> images[].newTag, then:
kubectl apply -k stayledger-admin-web/production/
kubectl rollout status deployment/stayledger-admin-web -n stayledger
```

Emergency `set image` must include **both** `env-inject=` and `admin-web=` (see production/README.md).

---

## ✅ Verify the served bundle (do this after every admin-web deploy)

Confirming the running tag is **not enough** — verify the actual files inside the pod, because the
`env-inject` volume is what gets served.

```powershell
$pod = kubectl get pods -n stayledger-staging -l app=stayledger-admin-web -o jsonpath='{.items[0].metadata.name}'

# 1. BOTH images must be identical
kubectl get deploy stayledger-admin-web -n stayledger-staging `
  -o jsonpath='{range .spec.template.spec.initContainers[*]}init:{.image}{"\n"}{end}{range .spec.template.spec.containers[*]}main:{.image}{"\n"}{end}'

# 2. BUILD_ID inside the pod must change on every real deploy
kubectl exec -n stayledger-staging $pod -c admin-web -- cat /app/.next/BUILD_ID

# 3. (optional) grep for a marker string you just shipped
kubectl exec -n stayledger-staging $pod -c admin-web -- sh -c "grep -rl '<your-new-string>' /app/.next/static | head"
```

If BUILD_ID is unchanged after a deploy that changed source, `env-inject` is still on the old image —
re-run `kubectl apply -k` (or set both containers).

---

## Health Checks

```bash
curl https://app.stayledger.io/healthz         # production (ingress)
curl https://stg-app.stayledger.io/healthz     # staging (ingress)
curl http://hkk8s-hub-master:30010/healthz     # staging (NodePort fallback)
```

## Rollback

```bash
kubectl rollout undo deployment/stayledger-admin-web -n stayledger           # production
kubectl rollout undo deployment/stayledger-admin-web -n stayledger-staging   # staging
```

`rollout undo` reverts **both** containers together (it restores the whole pod template), so it is
safe with respect to the init-container drift issue.

## NodePorts

| Environment | NodePort | Ingress host           |
|-------------|----------|------------------------|
| Production  | —        | app.stayledger.io      |
| Staging     | 30010    | stg-app.stayledger.io  |
