# StayLedger Infra — cấu trúc folder (staging / production)

Repo này là **GitOps source of truth** cho Kubernetes, không phải dump trực tiếp từ cluster. Mỗi app có pattern **Kustomize**: `base/` + overlay `staging/` hoặc `production/`.

## Sơ đồ tổng quan

```text
stayledger-infra/
├── stayledger-shared/          # Dùng chung cả cluster (1 lần / env)
│   ├── observability/          # Prometheus, Grafana, Loki, rules, dashboards
│   ├── datastores/             # Postgres, Redis, PgBouncer, backup CronJobs
│   └── argocd/                 # ArgoCD install + Application staging
│
├── stayledger-api/             # PMS backend + AI worker + guest-docs backup
│   ├── base/                   # Deployment api, ai-worker, HPA, CronJob doc backup, ServiceMonitor
│   ├── staging/                # overlay ns stayledger-staging, NodePort api :30011
│   └── production/             # overlay ns stayledger, Ingress, không NodePort
│
├── stayledger-admin-web/       # Admin UI (Next.js + env-inject initContainer)
│   ├── base/
│   ├── staging/                # ns stayledger-staging, NodePort :30010
│   └── production/             # ns stayledger, Ingress app.stayledger.io
│
├── stayledger-landing/         # Marketing site (ít file hơn api/admin)
│   ├── staging/
│   └── prd/                    # production manifests (tên legacy prd/)
│
└── stayledger-ai-assistant-api/       # AI API + workers + dedicated datastores (ns stayledger-ai-assistant)
    ├── base/app|datastores|scaling|security/
    ├── staging/
    ├── production/
    ├── observability/
    └── argocd/

└── stayledger-ai-assistant-admin-web/ # AI admin UI (same ns; apply after API)
    ├── base/
    ├── staging/
    ├── production/
    └── argocd/
```

## Cluster ↔ namespace ↔ folder

| Môi trường | kubectl context | Namespace PMS | Namespace AI | Observability |
|---|---|---|---|---|
| Staging | `HK-HUB-Cluster` | `stayledger-staging` | `stayledger-ai-assistant` | `observability` |
| Production | `stayledger` | `stayledger` | `stayledger-ai-assistant` | `observability` |

## Resource thuộc project nào? (PMS namespace)

| Tên resource trên cluster | Folder GitOps |
|---|---|
| `stayledger-admin-web` (Deploy/Service/Ingress/HPA/CM `stayledger-admin-web-config`) | `stayledger-admin-web/` |
| `stayledger-api`, `stayledger-ai-worker`, CM `stayledger-api-config`, Ingress `stayledger-api`, ServiceMonitor api/ai-worker, CronJob `stayledger-document-backup-offnode`, PVC guest-documents, migration Job | `stayledger-api/` |
| `stayledger-landing`, CM landing/nginx | `stayledger-landing/` |
| `stayledger-postgres` (STS), `stayledger-redis`, `stayledger-pgbouncer`, backup CronJobs postgres*, CM postgres/redis/pgbouncer, Secret `stayledger-*-secrets`, `pgbouncer-secret`, backup S3 | `stayledger-shared/datastores/{staging\|production}/` |
| `stayledger-api-nodeport` (staging only) | Patch trong `stayledger-api/staging/` hoặc production patch xóa NodePort |
| Grafana, Prometheus, rules, dashboard CM | `stayledger-shared/observability/` |
| `hotel-assistant-api`, workers, datastores, observability | `stayledger-ai-assistant-api/` |
| `hotel-assistant-frontend` | `stayledger-ai-assistant-admin-web/` |

## Pattern Kustomize (ví dụ admin-web)

```text
stayledger-admin-web/
├── base/
│   ├── kustomization.yaml      # resources: deployment, hpa, pdb, ...
│   └── deployment.yaml         # spec chung (2 container: env-inject + admin-web)
├── staging/
│   ├── kustomization.yaml      # namespace + images digest + patches
│   ├── configmap.yaml          # NEXT_PUBLIC_* staging
│   └── patches/deployment-staging.yaml
└── production/
    ├── kustomization.yaml
    ├── configmap.yaml
    ├── ingress.yaml
    └── patches/...
```

**Deploy:**

```powershell
kubectl apply -k stayledger-admin-web/staging/    # HK-HUB-Cluster
kubectl apply -k stayledger-api/production/       # context stayledger
```

## Export cluster vs Git (quan trọng)

| | Cluster export (`kubectl get -o yaml`) | Folder `stayledger-infra/` |
|---|---|---|
| Mục đích | Snapshot live, audit, drift review | Source để apply lại |
| Secret | Có data base64 thật | Chỉ `*.example.yaml` / template; secret apply riêng |
| Metadata | `resourceVersion`, `uid`, `status`, last-applied | Đã strip / không commit |
| Cách dùng | So sánh với `kubectl kustomize` output | `kubectl apply -k` |

Snapshot export theo project (không commit secret):  
`artifacts/infra-export-<timestamp>/by-project/`

## Drift review workflow

1. Export cluster → `artifacts/infra-export-.../`
2. Split theo project → `by-project/staging|production/...`
3. So sánh từng Deployment/CM với `stayledger-infra/<project>/staging|production/`
4. Chỉ merge thay đổi **có chủ đích** vào Git (patch/kustomization), không copy nguyên file export.
