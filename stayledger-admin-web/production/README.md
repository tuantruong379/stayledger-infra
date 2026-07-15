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

```powershell
export IMAGE_TAG=a1b2c3d
kubectl set image deployment/stayledger-admin-web \
  env-inject=putin111/stayledger-admin-web:${IMAGE_TAG} \
  admin-web=putin111/stayledger-admin-web:${IMAGE_TAG} \
  -n stayledger
kubectl rollout status deployment/stayledger-admin-web -n stayledger
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
