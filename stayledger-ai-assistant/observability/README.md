# Observability — active apply index

Namespace: `observability`. Workload metrics from `stayledger-ai` namespace via ServiceMonitors.

## Helm values (install separately)

| File | Chart |
|------|--------|
| [kube-prometheus-stack-values.yaml](kube-prometheus-stack-values.yaml) | `kube-prometheus-stack` (`kps`) |
| [loki-values-v3.yaml](loki-values-v3.yaml) | `loki` (v3) |
| [promtail-values.yaml](promtail-values.yaml) | `promtail` |
| [tempo-values.yaml](tempo-values.yaml) | `tempo` |

Step-by-step: [SETUP.md](SETUP.md). Operator guide: [docs/operations/observability.md](../../docs/operations/observability.md).

## Plain manifests (`kubectl apply -f`)

- [namespace.yaml](namespace.yaml), [storage-pvs.yaml](storage-pvs.yaml)
- [otel-collector.yaml](otel-collector.yaml)
- [servicemonitor-api.yaml](servicemonitor-api.yaml) — scrape `/metrics/prom`
- [servicemonitor-datastores.yaml](servicemonitor-datastores.yaml)
- PrometheusRules: [prometheus-rules.yaml](prometheus-rules.yaml), [prometheus-recording-rules.yaml](prometheus-recording-rules.yaml), [prometheus-infrastructure-alerts.yaml](prometheus-infrastructure-alerts.yaml), [hotel-ai-alerts.yaml](hotel-ai-alerts.yaml), [metrics-pipeline-alerts.yaml](metrics-pipeline-alerts.yaml), [datastore-exporter-alerts.yaml](datastore-exporter-alerts.yaml)
- Grafana dashboards (ConfigMaps, label `grafana_dashboard: "1"`, folder `StayLedger AI`): golden-signals, llm-cost, slo, pricing-booking, kpi-cost-errors-logs
- [rbac.yaml](rbac.yaml), [resource-quotas.yaml](resource-quotas.yaml), [pod-disruption-budgets.yaml](pod-disruption-budgets.yaml)

## Secrets (not in git)

Copy and apply locally:

- [grafana-admin-secret.example.yaml](grafana-admin-secret.example.yaml) → `grafana-admin-secret.yaml` (gitignored)
- [alertmanager-secrets.example.yaml](alertmanager-secrets.example.yaml) → `alertmanager-secrets.yaml` (gitignored)

## Archived

Legacy files: [docs/archive/observability/2026-05-19/](../../docs/archive/observability/2026-05-19/).
