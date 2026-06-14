# Minimal app-only manifests

Standalone Kubernetes YAML for API + frontend only. Assumes PostgreSQL, Redis, and ConfigMaps/Secrets already exist outside this folder.

**Production deploy:** use [../base/](../base/) (Kustomize) instead — full stack with datastores, workers, scaling, and network policies.

## Files

| File | Contents |
| --- | --- |
| `namespace.yaml` | `stayledger` namespace, ResourceQuota, LimitRange |
| `api-deployment.yaml` | API Deployment, Service, alembic init container |
| `frontend-deployment.yaml` | Frontend Deployment and Service |
| `hpa.yaml` | CPU/memory HPAs for API and frontend |
| `pdb.yaml` | PodDisruptionBudgets |
| `network-policy.yaml` | Default-deny plus ingress-controller and datastore egress rules |

## Apply order

```powershell
# From stayledger-infra repo root
kubectl apply -f stayledger-ai-assistant/minimal/namespace.yaml
# Create ai-hotel-assistant-secrets, ai-hotel-assistant-config,
# ai-hotel-assistant-frontend-config before workloads (see comments in yaml).
kubectl apply -f stayledger-ai-assistant/minimal/api-deployment.yaml
kubectl apply -f stayledger-ai-assistant/minimal/frontend-deployment.yaml
kubectl apply -f stayledger-ai-assistant/minimal/hpa.yaml
kubectl apply -f stayledger-ai-assistant/minimal/pdb.yaml
kubectl apply -f stayledger-ai-assistant/minimal/network-policy.yaml
```

Pin image tags to CI-built SHAs; do not rely on `:latest` in production.
