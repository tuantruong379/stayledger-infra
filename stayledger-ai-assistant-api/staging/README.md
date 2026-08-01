# AI Assistant — staging (NodePort)

| Surface | Public URL | NodePort |
| --- | --- | --- |
| Admin UI + guest chat | `https://stg-assistant.stayledger.io` | **30081** |
| FastAPI API | `https://stg-api-assistant.stayledger.io` | **30080** |

Staging uses **NodePort only** (no Kubernetes Ingress). Cloudflare terminates TLS and
proxies to the cluster node ports (same pattern as `stg-app` / `stg-api` for PMS).

## DNS

Point both hostnames at the cluster node (same target as `stg-app.stayledger.io` /
`stg-api.stayledger.io`). Cloudflare should forward to:

| Host | NodePort |
| --- | --- |
| `stg-assistant.stayledger.io` | 30081 |
| `stg-api-assistant.stayledger.io` | 30080 |

Direct node access (bypass Cloudflare):

```bash
curl -fsS http://<node-ip>:30080/health
curl -fsS http://<node-ip>:30081/
```

## Deploy

```powershell
# Secrets (once) — see ../base/ README
kubectl apply -f stayledger-ai-assistant-api/base/app/hotel-assistant-api-secret.yaml
kubectl apply -f stayledger-ai-assistant-admin-web/base/app/hotel-assistant-frontend-secret.yaml
# ... other base secrets as needed

kubectl apply -k stayledger-ai-assistant-api/staging/
kubectl apply -k stayledger-ai-assistant-admin-web/staging/

kubectl rollout restart deployment/hotel-assistant-frontend deployment/hotel-assistant-api -n stayledger-ai-assistant
```

Do **not** apply `ingress.yaml` — staging is NodePort-only.

## Frontend → API routing

`NEXT_PUBLIC_API_BASE_URL` in the staging ConfigMap must be the **in-cluster** API service:

```yaml
NEXT_PUBLIC_API_BASE_URL: "http://hotel-assistant-api:8000"
```

The frontend NetworkPolicy only allows egress to `hotel-assistant-api:8000`. Do **not** set this
to the public Cloudflare URL — server-side Next.js rewrites would fail with 500.

Browsers still use `https://stg-assistant.stayledger.io` and same-origin `/api/*` paths.

## Verify

```bash
curl -fsS https://stg-assistant.stayledger.io/
curl -fsS https://stg-api-assistant.stayledger.io/health
curl -fsS https://stg-api-assistant.stayledger.io/readyz

# API root should redirect browsers to the admin login UI
curl -sS -D - -o /dev/null https://stg-api-assistant.stayledger.io/
# Location: https://stg-assistant.stayledger.io/admin/login
```

## Local / CI

- Frontend runtime API origin: `NEXT_PUBLIC_API_BASE_URL=https://stg-api-assistant.stayledger.io`
- E2E / k6: `HOTEL_ASSISTANT_BASE_URL=https://stg-api-assistant.stayledger.io`
