# Staging — AI Assistant Admin Web

Apply after `stayledger-ai-assistant-api/staging/` (same namespace).

```powershell
kubectl apply -f stayledger-ai-assistant-admin-web/base/app/hotel-assistant-frontend-secret.yaml
kubectl apply -k stayledger-ai-assistant-admin-web/staging/
kubectl rollout status deployment/hotel-assistant-frontend -n stayledger-ai-assistant
```
