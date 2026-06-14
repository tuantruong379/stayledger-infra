# infra

Central Kubernetes infrastructure repository for the StayLedger platform. All manifests for every project are organised here by project, with shared cluster-wide components in `stayledger-shared/`.

## Structure

```text
infra/
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
│   ├── prd/                        # Production deployment
│   └── staging/                    # Staging deployment
│
├── stayledger-admin-web/           # StayLedger admin web frontend
│   ├── prd/
│   └── staging/
│
└── stayledger-ai-assistant/        # StayLedger AI Assistant (hotel chatbot)
    ├── base/                       # Kustomize root → kubectl apply -k infra/stayledger-ai-assistant/base/
    │   ├── app/                    # API, frontend, workers, alembic job
    │   ├── datastores/             # PostgreSQL, Redis, PgBouncer, NATS (app-dedicated)
    │   ├── scaling/                # HPAs, PDB
    │   ├── security/
    │   │   ├── kyverno/            # Pod security policies
    │   │   └── network-policies/   # Zero-trust NetworkPolicy rules
    │   └── disabled/tls-edge/      # TLS + ingress (staged, not active)
    ├── argocd/                     # ArgoCD Application + Project (GitOps)
    └── observability/              # App-specific alerts, dashboards, servicemonitors
        ├── alerts/
        ├── dashboards/
        ├── recording-rules/
        └── servicemonitors/
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
cd infra/stayledger-shared/argocd/install
.\install.ps1      # or: bash install.sh on Linux/macOS
kubectl apply -f argocd-params.yaml
kubectl apply -f argocd-nodeport.yaml

# Staging Application manifests
kubectl apply -f infra/stayledger-shared/argocd/staging/
```

### 1. Shared observability (once per cluster)

```powershell
cd infra/stayledger-shared/observability
.\install.ps1

kubectl apply -f infra/stayledger-shared/observability/namespace.yaml
kubectl apply -f infra/stayledger-shared/observability/rbac.yaml
kubectl apply -f infra/stayledger-shared/observability/storage-pvs.yaml
kubectl apply -f infra/stayledger-shared/observability/resource-quotas.yaml
kubectl apply -f infra/stayledger-shared/observability/pod-disruption-budgets.yaml
kubectl apply -f infra/stayledger-shared/observability/exporters/
kubectl apply -f infra/stayledger-shared/observability/otel-collector/
kubectl apply -f infra/stayledger-shared/observability/alerting/
kubectl apply -f infra/stayledger-shared/observability/grafana/dashboards/
```

### 2. Shared datastores

```powershell
# Copy secret templates → fill in real values → apply (gitignored)
kubectl apply -f infra/stayledger-shared/datastores/prd/
```

### 3. Per-project workloads

**stayledger-api / stayledger-admin-web:**

```powershell
kubectl apply -f infra/stayledger-api/prd/
kubectl apply -f infra/stayledger-admin-web/prd/
```

**stayledger-ai-assistant (Kustomize):**

```powershell
# Apply secrets first
kubectl apply -f infra/stayledger-ai-assistant/base/datastores/redis-secret.yaml
kubectl apply -f infra/stayledger-ai-assistant/base/datastores/pgbouncer-secret.yaml
kubectl apply -f infra/stayledger-ai-assistant/base/app/hotel-assistant-api-secret.yaml
kubectl apply -f infra/stayledger-ai-assistant/base/app/hotel-assistant-smtp-secret.yaml
kubectl apply -f infra/stayledger-ai-assistant/base/app/hotel-assistant-frontend-secret.yaml

# Apply stack
kubectl apply -k infra/stayledger-ai-assistant/base/

# App-specific observability
kubectl apply -f infra/stayledger-ai-assistant/observability/servicemonitors/
kubectl apply -f infra/stayledger-ai-assistant/observability/alerts/
kubectl apply -f infra/stayledger-ai-assistant/observability/recording-rules/
kubectl apply -f infra/stayledger-ai-assistant/observability/dashboards/
```

### 4. GitOps (ArgoCD manages stayledger-ai-assistant automatically)

```powershell
kubectl apply -f infra/stayledger-ai-assistant/argocd/project.yaml
kubectl apply -f infra/stayledger-ai-assistant/argocd/hotel-assistant-application.yaml
```

## Adding a new project

1. Create `infra/<project-name>/` with `prd/` and `staging/` subdirectories.
2. If the project needs dedicated datastores, add them there or reuse `stayledger-shared/datastores/`.
3. If the project has its own alert rules or Grafana dashboards, add an `observability/` subfolder.
4. Shared cluster tooling (Prometheus, Loki, Tempo, ArgoCD) stays in `stayledger-shared/` — do not duplicate.

## Source repos

| Project | Application repo | Infra folder |
| --- | --- | --- |
| StayLedger API | `stayledger-api/` | `infra/stayledger-api/` |
| StayLedger Admin Web | `stayledger-admin-web/` | `infra/stayledger-admin-web/` |
| StayLedger AI Assistant | `stayledger-ai-assistant/` | `infra/stayledger-ai-assistant/` |
| Shared cluster infra | `stayledger-shared/` | `infra/stayledger-shared/` |
