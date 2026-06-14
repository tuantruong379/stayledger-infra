# StayLedger observability stack

Namespace: `observability`. Unified from `ai-hotel-assistant/k8s/observability/` and archived docs.

## Helm charts (install via `install.ps1`)

| File | Chart | Release name |
|------|-------|--------------|
| [helm/kube-prometheus-stack-values.yaml](helm/kube-prometheus-stack-values.yaml) | `kube-prometheus-stack` | `kps` |
| [helm/loki-values-v3.yaml](helm/loki-values-v3.yaml) | `loki` (v3 single binary) | `loki` |
| [helm/promtail-values.yaml](helm/promtail-values.yaml) | `promtail` | `promtail` |
| [helm/tempo-values.yaml](helm/tempo-values.yaml) | `tempo` | `tempo` |

**Do not use** `helm/loki-stack-values.yaml` — deprecated Loki 2.x bundle.

## Plain manifests (`kubectl apply -f`)

- [namespace.yaml](namespace.yaml), [resource-quotas.yaml](resource-quotas.yaml)
- [grafana/dashboards/stayledger-pms/](grafana/dashboards/stayledger-pms/) — StayLedger PMS dashboards; see [dashboard guide](grafana/dashboards/stayledger-pms/README.md)
- [grafana/dashboards/stayledger-ai-assistant/](grafana/dashboards/stayledger-ai-assistant/) — StayLedger AI Assistant dashboards
- [exporters/](exporters/) — postgres, redis, pgbouncer exporters
- [otel-collector/](otel-collector/) — OTLP → Tempo
- [alerting/](alerting/) — PrometheusRules + Alertmanager config

## Plain manifests (also applied by install.ps1)

- [storage-pvs.yaml](storage-pvs.yaml) — local PVs + `observability-sc` StorageClass
- [rbac.yaml](rbac.yaml), [pod-disruption-budgets.yaml](pod-disruption-budgets.yaml)
- [alerting/](alerting/) — StayLedger rules + recording/infrastructure alerts (from hotel-ai migration)
- [examples/](examples/) — secret templates (not committed with real values)

## Quick install

```powershell
cd stayledger-shared/k8s/observability
.\install.ps1 -GrafanaPassword 'admin'
```

## Known issues fixed in values (2026-06-13)

1. **Grafana OOMKilled** — LimitRange default 256Mi is too low for Grafana 13; values set 512Mi request / 1Gi limit.
2. **Tempo gRPC errors in Grafana logs** — Explore Traces app speaks gRPC to port 3200 (HTTP); disable streaming in Tempo datasource.
3. **Chart mismatch** — live cluster uses `loki` + `promtail` separately, not `loki-stack`.

## Verify

```powershell
kubectl get pods -n observability
kubectl logs -n observability deploy/kps-grafana -c grafana --tail=50
kubectl exec -n observability deploy/kps-grafana -c grafana -- wget -qO- http://loki:3100/ready
```

Grafana: `http://<node-ip>:30030` · Prometheus NodePort: `30090`
