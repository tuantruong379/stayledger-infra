# stayledger-ai-assistant/

Kubernetes manifests for the StayLedger AI Assistant. Organised into three sub-trees:

| Folder | Purpose |
| --- | --- |
| [base/](base/) | Kustomize root — deploy with `kubectl apply -k stayledger-ai-assistant/base/` |
| [staging/](staging/) | Staging overlay — `assistant.stayledger.io` + `api-assistant.stayledger.io` |
| [minimal/](minimal/) | App-only raw YAML (API + frontend); external Postgres/Redis assumed |
| [argocd/](argocd/) | GitOps — ArgoCD Application targeting this path |
| [observability/](observability/) | App-specific alerts, dashboards, recording rules, servicemonitors |

## base/ layout

```text
base/
├── kustomization.yaml         # Kustomize root — references all sub-directories
├── namespace.yaml             # hotel-assistant namespace
├── serviceaccounts.yaml       # Service accounts
├── nginx-hotel-assistant.conf # Nginx reverse-proxy config (if used at edge)
├── app/                       # Workload deployments and configmaps
│   ├── hotel-assistant-api.yaml
│   ├── hotel-assistant-api-configmap.yaml
│   ├── hotel-assistant-api-secret.example.yaml     ← copy → hotel-assistant-api-secret.yaml (gitignored)
│   ├── hotel-assistant-channel-worker.yaml
│   ├── hotel-assistant-frontend.yaml
│   ├── hotel-assistant-frontend-configmap.yaml
│   ├── hotel-assistant-frontend-secret.example.yaml
│   ├── hotel-assistant-metrics-aggregator.yaml
│   ├── hotel-assistant-smtp-configmap.yaml
│   ├── hotel-assistant-smtp-secret.example.yaml
│   ├── hotel-assistant-tenant-email-routing-configmap.yaml
│   ├── hotel-assistant-webhook-worker.yaml
│   └── alembic-upgrade-job.yaml                    ← run before API pods start
├── datastores/                # PostgreSQL, Redis, PgBouncer, NATS
│   ├── postgres-*.yaml
│   ├── redis-*.yaml
│   ├── pgbouncer-*.yaml
│   └── nats.yaml
├── scaling/                   # Horizontal Pod Autoscalers + PDB
│   ├── api-hpa.yaml
│   ├── channel-worker-hpa.yaml
│   ├── frontend-hpa.yaml
│   ├── webhook-worker-hpa.yaml
│   └── pdb.yaml
├── security/
│   ├── kyverno/               # Pod security policies (Kyverno)
│   └── network-policies/      # Zero-trust NetworkPolicy (default-deny + per-service allow rules)
└── disabled/
    └── tls-edge/              # cert-manager issuer + ingress (TLS not yet active)
```

## Quick deploy

```powershell
# 1. Apply secrets from templates (gitignored)
kubectl apply -f stayledger-ai-assistant/base/datastores/redis-secret.yaml
kubectl apply -f stayledger-ai-assistant/base/datastores/pgbouncer-secret.yaml
kubectl apply -f stayledger-ai-assistant/base/app/hotel-assistant-api-secret.yaml
kubectl apply -f stayledger-ai-assistant/base/app/hotel-assistant-smtp-secret.yaml
kubectl apply -f stayledger-ai-assistant/base/app/hotel-assistant-frontend-secret.yaml

# 2. Run schema migration job (before API pods)
kubectl apply -f stayledger-ai-assistant/base/app/alembic-upgrade-job.yaml

# 3. Apply everything else via Kustomize
kubectl apply -k stayledger-ai-assistant/base/
```

On a fresh cluster, also run the one-time bootstrap job:

```powershell
kubectl apply -f stayledger-ai-assistant/base/datastores/postgres-bootstrap-job.yaml
# DO NOT re-run on an existing cluster — Jobs are immutable
```

For direct DB access (DBeaver, psql):

```powershell
kubectl apply -f stayledger-ai-assistant/base/datastores/postgres-service-nodeport.yaml
```

## argocd/

ArgoCD Application pointing at `stayledger-ai-assistant/base/` in this repo. Apply once; ArgoCD handles all subsequent syncs automatically.

```powershell
kubectl apply -f stayledger-ai-assistant/argocd/project.yaml
kubectl apply -f stayledger-ai-assistant/argocd/hotel-assistant-application.yaml
```

## observability/

App-specific observability resources — install after the shared observability stack from `stayledger-shared/observability/` is running.

```powershell
kubectl apply -f stayledger-ai-assistant/observability/servicemonitors/
kubectl apply -f stayledger-ai-assistant/observability/alerts/
kubectl apply -f stayledger-ai-assistant/observability/recording-rules/
kubectl apply -f stayledger-ai-assistant/observability/dashboards/
```

## Image tags

Image names and tags are managed in `base/kustomization.yaml` under the `images:` block. The ArgoCD Image Updater annotation in `argocd/hotel-assistant-application.yaml` keeps these in sync with the latest CI-built images automatically.

## See Also

- [README.md](../README.md) — top-level stayledger-infra overview
- [stayledger-shared/observability/](../stayledger-shared/observability/) — cluster-wide observability stack
- [docs/KUBERNETES.md](../../stayledger-ai-assistant/docs/KUBERNETES.md) — full Kubernetes deployment guide
