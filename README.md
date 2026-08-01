# stayledger-infra

Central Kubernetes infrastructure repository for the StayLedger platform. All manifests for every project are organised here by project, with shared cluster-wide components in `stayledger-shared/`.

## Clusters

| Environment | kubectl context | Typical namespaces | Overlay / install |
|---|---|---|---|
| **Staging** | `HK-HUB-Cluster` | `stayledger-staging`, `stayledger-ai-assistant`, `observability` | `**/staging/`, `observability/install.ps1` |
| **Production** | `stayledger` | `stayledger`, `stayledger-ai-assistant`, `observability` | `**/production/`, `observability/install-production.ps1` |

Always confirm context before apply:

```powershell
kubectl config current-context   # expect HK-HUB-Cluster (staging) or stayledger (production)
kubectl config use-context stayledger          # production
kubectl config use-context HK-HUB-Cluster      # staging
```

**Production releases:** use `scripts/deploy-production-stayledger-safe.ps1` (requires explicit image tags and `-ConfirmProd`). Canonical runbooks live in workspace [docs/deployment/](../docs/deployment/README.md).

**Folder layout (Vietnamese guide + resource mapping):** [docs/FOLDER-STRUCTURE.md](docs/FOLDER-STRUCTURE.md)

**Split cluster export by project:** `node scripts/split-infra-export-by-project.mjs <artifacts/infra-export-dir>` (requires `npm install yaml` in `scripts/` or run from CI).

## Structure

```text
stayledger-infra/
├── stayledger-shared/
│   ├── argocd/                     # ArgoCD installation + staging Application manifests
│   │   ├── install/                # ArgoCD install scripts and params (cluster-wide)
│   │   └── staging/                # ArgoCD Applications: api, admin-web, infrastructure
│   ├── observability/              # Cluster-wide observability stack
│   │   ├── helm/                   # Helm values: kube-prometheus-stack, Loki, Tempo, Promtail
│   │   ├── alerting/               # PrometheusRules and AlertManager config
│   │   ├── grafana/dashboards/     # Grafana dashboard ConfigMaps
│   │   ├── exporters/              # postgres-exporter, redis-exporter, pgbouncer-exporter
│   │   ├── otel-collector/         # OpenTelemetry collector
│   │   ├── examples/               # Secret templates (alertmanager, grafana-admin)
│   │   ├── namespace.yaml
│   │   ├── rbac.yaml
│   │   ├── storage-pvs.yaml
│   │   ├── pod-disruption-budgets.yaml
│   │   ├── resource-quotas.yaml
│   │   └── install.ps1             # Helm install script
│   └── datastores/                 # Shared PostgreSQL, Redis, PgBouncer
│       ├── prd/                    # Production datastores
│       ├── staging/                # Staging datastores
│       ├── postgres-local.conf     # Local tuning reference
│       └── redis-local.conf
│
├── stayledger-api/                 # StayLedger PMS backend API
│   ├── base/                       # Kustomize base
│   ├── production/                 # Production overlay → kubectl apply -k
│   └── staging/                    # Staging overlay → kubectl apply -k
│
├── stayledger-admin-web/           # StayLedger admin web frontend (env-inject init container)
│   ├── base/                       # Kustomize base (env-inject + admin-web share one image)
│   ├── production/                 # Production overlay → kubectl apply -k
│   └── staging/                    # Staging overlay → kubectl apply -k
│
└── stayledger-ai-assistant-api/    # AI Assistant API + workers + dedicated datastores
    ├── base/                       # Kustomize root → kubectl apply -k stayledger-ai-assistant-api/base/
    │   ├── app/                    # API, workers, alembic job
    │   ├── datastores/             # PostgreSQL, Redis, PgBouncer, NATS (app-dedicated)
    │   ├── scaling/                # HPAs, PDB
    │   ├── security/
    │   │   ├── kyverno/            # Pod security policies
    │   │   └── network-policies/   # Zero-trust NetworkPolicy rules
    │   └── disabled/tls-edge/      # TLS + ingress (staged, not active)
    ├── argocd/                     # ArgoCD Project + API Application
    └── observability/              # App-specific alerts, dashboards, servicemonitors

└── stayledger-ai-assistant-admin-web/  # AI Assistant admin UI (same namespace)
    ├── base/                       # Frontend Deployment/Service/HPA/NetworkPolicy
    ├── staging/
    ├── production/
    └── argocd/                     # Admin-web Application
```

## Shared vs Project-specific

| Layer | Location | Scope |
| --- | --- | --- |
| ArgoCD installation | `stayledger-shared/argocd/install/` | Cluster-wide — install once |
| Staging ArgoCD apps | `stayledger-shared/argocd/staging/` | All staging workloads |
| Observability stack | `stayledger-shared/observability/` | All clusters — install once via Helm |
| Shared datastores | `stayledger-shared/datastores/` | PostgreSQL, Redis, PgBouncer used by multiple projects |
| App-specific dashboards & alerts | `<project>/observability/` | Scoped to that project only |
| App workloads | `<project>/base/` or `<project>/prd/staging/` | That project only |

## Deploy order

### 0. Install ArgoCD (once per cluster)

```powershell
cd stayledger-shared/argocd/install
.\install.ps1      # or: bash install.sh on Linux/macOS
kubectl apply -f argocd-params.yaml
kubectl apply -f argocd-nodeport.yaml

# Staging Application manifests
kubectl apply -f stayledger-shared/argocd/staging/
```

### 1. Shared observability (once per cluster)

```powershell
cd stayledger-shared/observability
.\install.ps1

kubectl apply -f stayledger-shared/observability/namespace.yaml
kubectl apply -f stayledger-shared/observability/rbac.yaml
kubectl apply -f stayledger-shared/observability/storage-pvs.yaml
kubectl apply -f stayledger-shared/observability/resource-quotas.yaml
kubectl apply -f stayledger-shared/observability/pod-disruption-budgets.yaml
kubectl apply -f stayledger-shared/observability/exporters/
kubectl apply -f stayledger-shared/observability/otel-collector/
kubectl apply -f stayledger-shared/observability/alerting/
kubectl apply -f stayledger-shared/observability/grafana/dashboards/
```

### 2. Shared datastores

```powershell
# Copy secret templates → fill in real values → apply (gitignored)
kubectl apply -f stayledger-shared/datastores/prd/
```

### 3. Per-project workloads

**stayledger-api / stayledger-admin-web (Kustomize overlays):**

```powershell
kubectl apply -k stayledger-api/production/
kubectl apply -k stayledger-admin-web/production/
```

> **Always use `-k` (Kustomize), never `-f`, for `stayledger-admin-web`.** Its Deployment runs an
> `env-inject` init container that serves the bundle; the `images:` transformer keeps that init
> container and the main container on the same image. `kubectl apply -f` or `kubectl set image admin-web=…`
> alone updates only one of them and the pod silently serves stale JS. See
> `stayledger-admin-web/README.md` → "CRITICAL — the `env-inject` init container serves the bundle".

**stayledger-ai-assistant-api + admin-web (Kustomize):**

```powershell
# Apply secrets first (API + UI)
kubectl apply -f stayledger-ai-assistant-api/base/datastores/redis-secret.yaml
kubectl apply -f stayledger-ai-assistant-api/base/datastores/pgbouncer-secret.yaml
kubectl apply -f stayledger-ai-assistant-api/base/app/hotel-assistant-api-secret.yaml
kubectl apply -f stayledger-ai-assistant-api/base/app/hotel-assistant-smtp-secret.yaml
kubectl apply -f stayledger-ai-assistant-admin-web/base/app/hotel-assistant-frontend-secret.yaml

# Apply stacks (same namespace stayledger-ai-assistant)
kubectl apply -k stayledger-ai-assistant-api/base/
kubectl apply -k stayledger-ai-assistant-admin-web/base/

# App-specific observability (API tree)
kubectl apply -f stayledger-ai-assistant-api/observability/servicemonitors/
kubectl apply -f stayledger-ai-assistant-api/observability/alerts/
kubectl apply -f stayledger-ai-assistant-api/observability/recording-rules/
kubectl apply -f stayledger-ai-assistant-api/observability/dashboards/
```

### 4. GitOps (ArgoCD manages AI Assistant automatically)

```powershell
kubectl apply -f stayledger-ai-assistant-api/argocd/project.yaml
kubectl apply -f stayledger-ai-assistant-api/argocd/hotel-assistant-api-application.yaml
kubectl apply -f stayledger-ai-assistant-admin-web/argocd/hotel-assistant-admin-web-application.yaml
```

### Staging TLS edge (PMS admin + API)

Point DNS `stg-app.stayledger.io` and `stg-api.stayledger.io` at the cluster ingress
controller, then:

```powershell
# Update frontend-url in the cluster secret (email links, invites)
kubectl patch secret stayledger-staging-secrets -n stayledger-staging --type merge `
  -p '{"stringData":{"frontend-url":"https://stg-app.stayledger.io"}}'

kubectl apply -f stayledger-shared/staging/tls-edge/cert-manager-issuer.yaml
kubectl apply -f stayledger-shared/staging/ingress.yaml
kubectl apply -k stayledger-api/staging/
kubectl apply -k stayledger-admin-web/staging/   # -k (not -f): keeps env-inject + admin-web in sync
```

Verify:

```bash
curl -fsS https://stg-app.stayledger.io/healthz
curl -fsS https://stg-api.stayledger.io/api/health
```

### Staging (AI Assistant — NodePort)

Public URLs via Cloudflare → node ports (no ingress):

| Surface | URL | NodePort |
| --- | --- | --- |
| UI | `https://stg-assistant.stayledger.io` | 30081 |
| API | `https://stg-api-assistant.stayledger.io` | 30080 |

```powershell
kubectl apply -k stayledger-ai-assistant-api/staging/
kubectl apply -k stayledger-ai-assistant-admin-web/staging/
kubectl rollout restart deployment/hotel-assistant-frontend deployment/hotel-assistant-api -n stayledger-ai-assistant
```

Verify:

```bash
curl -fsS https://stg-assistant.stayledger.io/
curl -fsS https://stg-api-assistant.stayledger.io/health
```

See [stayledger-ai-assistant-api/staging/README.md](stayledger-ai-assistant-api/staging/README.md) and [stayledger-ai-assistant-admin-web/staging/README.md](stayledger-ai-assistant-admin-web/staging/README.md).

**Cloudflare note:** `/_next/static/*` is cached as `immutable` for 1 year. After changing
`NEXT_PUBLIC_*` via ConfigMap/env-inject only (without a new image build), purge Cloudflare
cache for `stg-app.stayledger.io/_next/static/*` or rebuild/push a new image so chunk hashes
change. Otherwise browsers keep loading stale JS with the old API URL.

## Adding a new project

1. Create `<project-name>/` with `prd/` and `staging/` subdirectories inside this repo.
2. If the project needs dedicated datastores, add them there or reuse `stayledger-shared/datastores/`.
3. If the project has its own alert rules or Grafana dashboards, add an `observability/` subfolder.
4. Shared cluster tooling (Prometheus, Loki, Tempo, ArgoCD) stays in `stayledger-shared/` — do not duplicate.

## Source repos

| Project | Application repo | Infra folder |
| --- | --- | --- |
| StayLedger API | `stayledger-api/` | `stayledger-api/` |
| StayLedger Admin Web | `stayledger-admin-web/` | `stayledger-admin-web/` |
| StayLedger AI Assistant API | `stayledger-ai-assistant-api/` | `stayledger-ai-assistant-api/` |
| StayLedger AI Assistant Admin Web | `stayledger-ai-assistant-admin-web/` | `stayledger-ai-assistant-admin-web/` |
| Shared cluster infra | `stayledger-shared/` | `stayledger-shared/` |
