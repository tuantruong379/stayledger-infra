# Minimal app-only manifests

Standalone Kubernetes YAML for API + frontend only. Assumes PostgreSQL, Redis, and ConfigMaps/Secrets already exist outside this folder.

**Production deploy:** use [../base/](../base/) (Kustomize) instead — full stack with datastores, workers, scaling, and network policies.

## Files

| File | Contents |
| --- | --- |
| `namespace.yaml` | `stayledger` namespace, ResourceQuota, LimitRange |
| `stayledger-ai-assistant-api-deployment.yaml` | API Deployment, Service, alembic init container |
| `admin-web-deployment.yaml` | Frontend Deployment and Service |
| `hpa.yaml` | CPU/memory HPAs for API and frontend |
| `pdb.yaml` | PodDisruptionBudgets |
| `network-policy.yaml` | Default-deny plus ingress-controller and datastore egress rules |

## Apply order

```powershell
# From stayledger-infra repo root
kubectl apply -f stayledger-ai-assistant/minimal/namespace.yaml
# Create ai-stayledger-ai-assistant-secrets, ai-stayledger-ai-assistant-config,
# ai-stayledger-ai-assistant-admin-web-config before workloads (see comments in yaml).
kubectl apply -f stayledger-ai-assistant/minimal/stayledger-ai-assistant-api-deployment.yaml
kubectl apply -f stayledger-ai-assistant/minimal/admin-web-deployment.yaml
kubectl apply -f stayledger-ai-assistant/minimal/hpa.yaml
kubectl apply -f stayledger-ai-assistant/minimal/pdb.yaml
kubectl apply -f stayledger-ai-assistant/minimal/network-policy.yaml
```

Pin image tags to CI-built SHAs; do not rely on `:latest` in production.
