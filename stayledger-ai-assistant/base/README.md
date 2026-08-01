# On-prem Kubernetes (hotel-assistant)

## 🆕 Multi-Tenant K8s Review & Fixes (2026-04-29)

**All critical misconfiguration and redundancy issues have been fixed.** See:

- **[FIXES_APPLIED.md](./FIXES_APPLIED.md)** — Summary of all fixes applied
- **[HA_MIGRATION_PLAN.md](./HA_MIGRATION_PLAN.md)** — Roadmap to production HA (12-15 weeks)

### Quick Start (Post-Fixes)

```bash
# 1. Label the data storage node (if not already done)
kubectl label nodes hkk8s-hub-master node-role.kubernetes.io/api-data=true --overwrite

# 2. Apply all manifests (including new HPA files)
kubectl apply -k k8s/onprem/

# 3. Verify deployments
kubectl get pods,hpa,networkpolicies -n stayledger-ai-assistant

# 4. Monitor HPA scaling
kubectl get hpa -n stayledger-ai-assistant --watch
```

### GitOps with Argo CD

```bash
# Register the Argo CD project/application after runtime secrets are present.
kubectl apply -k k8s/argocd/
kubectl -n argocd get application hotel-assistant-onprem
```

See [Deployment (GitOps)](../../docs/deployment/README.md#argo-cd-gitops-optional).

---

## Secrets vs tenant config (Phase C, DB-native)

| Source | Purpose |
| ------ | ------- |
| `hotel-assistant-api-secret.yaml` (from `*.example.yaml`, **gitignored**) | Shared secrets only: Azure OpenAI **API key**, Redis URL, `HOTEL_OPS_DSN` (+ optional `_DIRECT`), admin/feedback keys, `SECRET_ENCRYPTION_KEY`, `JWT_SECRET`, `STAYLEDGER_WEBHOOK_SIGNING_SECRET`, temporary global `API_KEY` fallback. Azure endpoint/deployment/version and `STAYLEDGER_PMS_INTERNAL_BASE_URL` belong in the ConfigMap. |
| `tenant_runtime_config` table (PostgreSQL) | **Per tenant:** display name, slug, `kb_path` (legacy hint), timezone, prompt profile, ICS/holiday data. Edited via `/admin/tenants/upsert`. |
| `tenants` table (PostgreSQL) | Page/OA id → `tenant_id` routing for webhooks. Edited via `/admin/tenants/upsert`. |
| `tenant_channel_secrets` table (PostgreSQL) | **Per tenant:** direct webhook API key, Meta credentials, and Zalo credentials. Sensitive values are encrypted on write, managed from Admin -> Tenant -> Config, and returned to UI as masked status only. |

Direct chat webhook auth (`POST /webhook*`) resolves keys in this order: tenant `webhook_api_key` from `tenant_channel_secrets`, then global `API_KEY` only while `WEBHOOK_REQUIRE_TENANT_API_KEY=0`. Set `WEBHOOK_REQUIRE_TENANT_API_KEY=1` after every tenant has a rotated key.

> **Phase C cleanup.** The API container is stateless and immutable: no `/data` PVC, no `/seed` ConfigMap, no `tenants_registry.json` seeding initContainer, no `config/tenants/*.json` mount. All runtime state is sourced from PostgreSQL.

## Billing (admin KPI + usage export)

- Server-side: set **`BILLING_USD_PER_1K_TOKENS`** in `hotel-assistant-api-config` (ConfigMap) or your API Secret; see **[docs/reference/README.md](../../docs/reference/README.md#billing-admin-dashboard-cost)**.
- Default **`0`** keeps cost at zero until you choose a blended rate from your Azure OpenAI pricing.

## Performance tuning (§7 speed review)

| Item | Manifest / code | Notes |
|------|-----------------|-------|
| API workers | `hotel-assistant-api-config` `UVICORN_WORKERS=2` | ~2 workers per 1 CPU request; raise CPU before workers |
| Frontend image | `hotel-assistant-frontend.yaml` + `kustomization.yaml` | Base tag is a placeholder; **always** `kubectl apply -k k8s/onprem/` |
| Worker readiness | webhook + channel worker `readinessProbe` | `check_worker_readiness()` — Redis + Postgres `SELECT 1` |
| HPA custom metrics | `hpa-external-metrics.example.yaml` | Optional; needs prometheus-adapter + `hotel_assistant_queue_depth` |
| Postgres connections | `postgres-tuning` `max_connections=100` | Budget: API replicas × `PG_POOL_MAX_SIZE` + workers + admin; use PgBouncer |

## Apply order (typical)

1. Namespace and storage classes (from `kustomization.yaml` resources).
2. `redis-secret.yaml` → then `hotel-assistant-api-secret.yaml` (Redis password must match `REDIS_URL`).
3. `kubectl apply -k k8s/onprem/`
4. Configure per-tenant webhook keys, channel IDs, and channel credentials in Admin -> Tenant -> Config.

## Multi-tenant notes

- **Direct webhook auth:** Use one `webhook_api_key` per tenant. The global `API_KEY` is a temporary fallback only; do not share it with tenant websites once per-tenant keys are rotated.
- **Global `FACEBOOK_*` / `ZALO_*`:** Avoid in multi-tenant production; use `tenant_channel_secrets` via Admin UI.

## Verifying in a running API pod

```bash
kubectl exec -n stayledger-ai-assistant deploy/hotel-assistant-api -- curl -fsS http://127.0.0.1:8000/readyz
kubectl exec -n stayledger-ai-assistant deploy/hotel-assistant-api -- curl -fsS http://127.0.0.1:8000/livez
```

Tenant runtime config is fetched from PostgreSQL (`tenant_runtime_config` table) at startup and refreshed via Redis Pub/Sub. Webhook/channel credentials are fetched from `tenant_channel_secrets` with a short in-process TTL.

## Tenant pricing/room/promo seed template

Use the shared database model (`hotel_ops`) with tenant-scoped rows (`tenant_id`) and generate SQL from a simple JSON declaration.

1. Copy `k8s/onprem/tenant-seed.vertex-suites-hanoi.example.json` and adjust `tenant_id`, `branches`, `room_types`, `pricing_rows`, `promotions`.
1. Generate SQL:

```bash
python scripts/generate_tenant_seed_sql.py \
  --input k8s/onprem/tenant-seed.my-new-tenant.json \
  --output k8s/onprem/generated/my-new-tenant.sql
```

1. Apply SQL into Postgres operational DB:

```bash
kubectl exec -i -n stayledger-ai-assistant deploy/postgres -- \
  psql -U "$POSTGRES_USER" -d hotel_ops < k8s/onprem/generated/my-new-tenant.sql
```

Generator behavior:

- Idempotent upserts for `tenants`, `branches`, `room_config`, `promotions`.
- Insert-if-missing for `pricing_rows` (safe re-run with unique indexes).
- No destructive deletes (existing rows remain unless manually removed).

## Tenant onboarding (Phase C)

Tenant runtime config and channel-id mappings live in PostgreSQL. The canonical
onboarding path is the admin API:

```bash
curl -X POST https://<api-host>/admin/tenants/upsert \
  -H "x-api-key: $ADMIN_API_KEY" \
  -H "Content-Type: application/json" \
  -d @payload.json
```

`payload.json` carries `tenant_id`, `slug`, `name`, `timezone`, prompt profile fields,
and (optionally) `facebook_page_ids` / `zalo_oa_ids` to populate the `tenants` mapping table.

Direct webhook keys and channel credentials are stored in `tenant_channel_secrets`
and managed from Admin -> Tenant -> Config. No per-tenant Kubernetes Secret or
Deployment volume changes are required for channel onboarding. Rotate the
tenant webhook key before sharing a tenant integration URL with an external
website backend.

## Knowledge Base (Postgres, DB-only)

KB runtime source of truth is **`kb_documents`** in PostgreSQL. Author markdown under `kb/` and import:

```bash
export HOTEL_OPS_DSN="postgresql://user:pass@postgres:5432/hotel_ops"
python scripts/import_kb_to_postgres.py --tenant-id my_new_tenant --kb-path kb/my_new_tenant_kb.md
```

Or edit via Admin UI (`/admin/tenants/<id>` → KB). Legacy `KB_SOURCE` and `config/tenants/*.json` are not read at runtime.
