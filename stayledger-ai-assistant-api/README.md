# stayledger-ai-assistant-api (infra)

Kubernetes manifests for the StayLedger AI Assistant **API**, workers, and dedicated datastores.

- Source code: https://github.com/tuantruong379/stayledger-ai-assistant-api
- Image: `putin111/ai-hotel-assistant`
- Namespace: `stayledger-ai-assistant` (shared with admin-web)
- Admin UI manifests: [`../stayledger-ai-assistant-admin-web/`](../stayledger-ai-assistant-admin-web/)

```powershell
kubectl apply -k stayledger-ai-assistant-api/staging/     # context HK-HUB-Cluster
kubectl apply -k stayledger-ai-assistant-api/production/  # context stayledger
```
