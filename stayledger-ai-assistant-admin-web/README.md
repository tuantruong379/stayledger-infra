# stayledger-ai-assistant-admin-web (infra)

Kubernetes manifests for the StayLedger AI Assistant **admin UI** (Next.js).

- Source code: https://github.com/tuantruong379/stayledger-ai-assistant-admin-web
- Image: `putin111/stayledger-ai-assistant-admin-web`
- Namespace: `stayledger-ai-assistant` (shared; apply API stack first)
- API manifests: [`../stayledger-ai-assistant-api/`](../stayledger-ai-assistant-api/)

```powershell
kubectl apply -k stayledger-ai-assistant-admin-web/staging/     # context HK-HUB-Cluster
kubectl apply -k stayledger-ai-assistant-admin-web/production/  # context stayledger
```
