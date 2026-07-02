# AI Assistant — staging (`stayledger.io`)

| Surface | URL |
| --- | --- |
| Admin UI + guest chat | `https://assistant.stayledger.io` |
| FastAPI API | `https://api-assistant.stayledger.io` |

## DNS

Point both hostnames at the cluster ingress controller (same target as `stg-app.stayledger.io` / `stg-api.stayledger.io`).

## Deploy

```powershell
# Secrets (once) — see ../base/ README
kubectl apply -f stayledger-ai-assistant/base/app/hotel-assistant-api-secret.yaml
kubectl apply -f stayledger-ai-assistant/base/app/hotel-assistant-frontend-secret.yaml
# ... other base secrets as needed

# Staging config + workloads
kubectl apply -k stayledger-ai-assistant/staging/

# TLS ingress
kubectl apply -f stayledger-shared/staging/tls-edge/cert-manager-issuer.yaml
kubectl apply -f stayledger-ai-assistant/staging/ingress.yaml

# Roll frontend + API so ConfigMap URL patches take effect
kubectl rollout restart deployment/hotel-assistant-frontend -n hotel-assistant
kubectl rollout restart deployment/hotel-assistant-api -n hotel-assistant
```

## Verify

```bash
curl -fsS https://assistant.stayledger.io/
curl -fsS https://api-assistant.stayledger.io/health
curl -fsS https://api-assistant.stayledger.io/readyz
```

## Local / CI

- Frontend runtime API origin: `NEXT_PUBLIC_API_BASE_URL=https://api-assistant.stayledger.io` (set in `frontend-configmap-patch.yaml`; injected at container start).
- E2E / k6: `HOTEL_ASSISTANT_BASE_URL=https://api-assistant.stayledger.io`
