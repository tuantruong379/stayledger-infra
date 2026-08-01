# Staging — AI Assistant Admin Web

Apply after `stayledger-ai-assistant-api/staging/` (same namespace).

```powershell
kubectl apply -f stayledger-ai-assistant-admin-web/base/app/stayledger-ai-assistant-admin-web-secret.yaml
kubectl apply -k stayledger-ai-assistant-admin-web/staging/
kubectl rollout status deployment/stayledger-ai-assistant-admin-web -n stayledger-ai-assistant
```
