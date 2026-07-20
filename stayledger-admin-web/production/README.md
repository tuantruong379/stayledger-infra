# stayledger-admin-web — Production Deployment

Namespace: `stayledger` | Domain: `app.stayledger.io` | NodePort: `30000`

## Apply order

```powershell
# Assumes datastores and API are already deployed (namespace + secrets exist).
export IMAGE_TAG=a1b2c3d   # 7-char short commit from CI (match API release; no sha- prefix)

sed "s|COMMIT_SHA|${IMAGE_TAG}|g" stayledger-admin-web/production/deployment.yaml | kubectl apply -f -
kubectl apply -f stayledger-admin-web/production/configmap.yaml
kubectl apply -f stayledger-admin-web/production/serviceaccount.yaml
kubectl apply -f stayledger-admin-web/production/networkpolicy.yaml
kubectl apply -f stayledger-admin-web/production/pdb.yaml
kubectl rollout status deployment/stayledger-admin-web -n stayledger

# Apply ingress after DNS propagates
kubectl apply -f stayledger-admin-web/production/ingress.yaml
```

## Rolling update

> **Prefer `kubectl apply -k`.** The `images:` transformer updates **both** the `env-inject` init
> container and the `admin-web` main container in lockstep. See the root `stayledger-admin-web/README.md`
> "CRITICAL — the `env-inject` init container serves the bundle" section for why this matters.

```powershell
# Recommended: bump images[].newTag in production/kustomization.yaml, then:
kubectl apply -k stayledger-admin-web/production/
kubectl rollout status deployment/stayledger-admin-web -n stayledger
```

Emergency `set image` only — you MUST set **both** containers or the pod will serve stale JS:

```powershell
export IMAGE_TAG=a1b2c3d
kubectl set image deployment/stayledger-admin-web \
  env-inject=putin111/stayledger-admin-web:${IMAGE_TAG} \
  admin-web=putin111/stayledger-admin-web:${IMAGE_TAG} \
  -n stayledger
kubectl rollout status deployment/stayledger-admin-web -n stayledger

# Verify the served bundle actually changed (not just the reported tag):
POD=$(kubectl get pods -n stayledger -l app=stayledger-admin-web -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n stayledger $POD -c admin-web -- cat /app/.next/BUILD_ID
```

## Post-deploy smoke checks

```bash
curl -fsS https://app.stayledger.io/healthz     # 200 OK
# Open https://app.stayledger.io in browser — login page should load
# Verify API calls succeed (no CORS or proxy errors in DevTools)
```

## URL injection

`NEXT_PUBLIC_API_URL` and `NEXT_PUBLIC_BOOKING_WEB_URL` are injected at runtime by the
`env-inject` init container without a rebuild. Change them in `configmap.yaml` and roll
the deployment; no new image is needed.
