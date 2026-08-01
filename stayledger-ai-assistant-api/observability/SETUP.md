# Observability Stack — Step-by-Step Setup Guide

> Active manifest index: [README.md](README.md). Operator guide: [docs/operations/observability.md](../../docs/operations/observability.md).

> Target cluster: on-prem single-node (`hkk8s-hub-master`), Kubernetes 1.35,
> Helm 4.x. No default StorageClass — uses pre-provisioned local PVs.
>
> Stack: kube-prometheus-stack + Loki/Promtail + Tempo + OTel Collector.
> Wires `stayledger-ai-api` (`/metrics/prom`, OTLP traces, JSON logs with
> `trace_id`+`span_id`) into Prometheus + Tempo + Loki, surfaced via Grafana.

---

## 0. Prerequisites

Run from a workstation with:

* `kubectl` pointing at the cluster (`kubectl get nodes` returns Ready).
* `helm` 3.13+ (we used 4.1).
* Cluster admin RBAC (the chart installs CRDs).
* Outbound HTTPS to `prometheus-community.github.io`, `grafana.github.io`,
  Docker Hub, and `quay.io`.
* The stayledger-ai API already deployed in namespace `stayledger-ai`
  with:
  * `Service stayledger-ai-api` exposing port `http` (8000).
  * `/metrics/prom` returning Prometheus exposition (Phase C1).
  * `OTEL_EXPORTER_OTLP_ENDPOINT` *not yet set* (we will set it in step 9).

Verify:

```powershell
kubectl get nodes
kubectl -n stayledger-ai get svc stayledger-ai-api
kubectl -n stayledger-ai exec deploy/stayledger-ai-api -- `
  curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:8000/metrics/prom
# expect: 200
```

---

## 1. Create the namespace

```powershell
kubectl apply -f k8s/observability/namespace.yaml
```

Why a separate namespace: keeps RBAC, PSPs/PSA, NetworkPolicies, and
quotas isolated from the workload. The Prometheus Operator scopes its
selectors to a list of namespaces (configured in step 3) including
`stayledger-ai`, so cross-namespace scraping still works.

---

## 2. Bootstrap on-disk paths for local PVs

The cluster has no dynamic provisioner. We pre-create five host directories
(one per stateful component) on the node, owned by UID/GID `65534`
(`nobody`) which matches the upstream Helm chart pod securityContexts.

```powershell
@"
apiVersion: batch/v1
kind: Job
metadata:
  name: bootstrap-obs-dirs
  namespace: observability
spec:
  ttlSecondsAfterFinished: 60
  template:
    spec:
      restartPolicy: Never
      nodeSelector: { kubernetes.io/hostname: hkk8s-hub-master }
      containers:
        - name: mk
          image: busybox:1.36
          securityContext: { runAsUser: 0 }
          command: ["sh","-c","mkdir -p /h/observability/prometheus /h/observability/alertmanager /h/observability/grafana /h/observability/loki /h/observability/tempo && chown -R 65534:65534 /h/observability && chmod -R 0775 /h/observability && ls -la /h/observability"]
          volumeMounts:
            - { name: hostmnt, mountPath: /h }
      volumes:
        - name: hostmnt
          hostPath: { path: /mnt/stayledger-ai, type: DirectoryOrCreate }
"@ | kubectl apply -f -
kubectl -n observability wait --for=condition=complete job/bootstrap-obs-dirs --timeout=120s
kubectl -n observability logs job/bootstrap-obs-dirs
# expect: drwxrwxr-x for prometheus / alertmanager / grafana / loki / tempo
```

If you ever recreate the node, re-run this Job — the host paths are
not part of any backup.

---

## 3. Define the StorageClass + pre-bound PVs

The PVs use `claimRef` to **deterministically pin** themselves to the
PVCs the Helm charts will create. This avoids the "Grafana steals
Alertmanager's PV" race we hit during first install.

```powershell
kubectl apply -f k8s/observability/storage-pvs.yaml

kubectl get pv | Select-String observability
# expect: 5 PVs in `Available` state, storageClassName=observability-sc,
#         each with a CLAIM column matching the PVC names below.
```

| PV | Size | Claim it pins to |
|---|---|---|
| `observability-prometheus-pv`   | 25Gi | `prometheus-kps-prometheus-db-prometheus-kps-prometheus-0` |
| `observability-alertmanager-pv` | 5Gi  | `alertmanager-kps-alertmanager-db-alertmanager-kps-alertmanager-0` |
| `observability-grafana-pv`      | 5Gi  | `kps-grafana` |
| `observability-loki-pv`         | 20Gi | `storage-loki-0` |
| `observability-tempo-pv`        | 20Gi | `storage-tempo-0` |

---

## 4. Add Helm repos

```powershell
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana              https://grafana.github.io/helm-charts
helm repo update
```

---

## 5. Install kube-prometheus-stack (Prometheus + Grafana + Alertmanager)

```powershell
helm upgrade --install kps prometheus-community/kube-prometheus-stack `
  -n observability --create-namespace `
  -f k8s/observability/kube-prometheus-stack-values.yaml `
  --timeout 10m
```

Wait for pods:

```powershell
kubectl -n observability wait --for=condition=ready pod `
  -l app.kubernetes.io/instance=kps --timeout=10m
kubectl -n observability get pod
# expect: prometheus-kps-prometheus-0 (2/2 Running),
#         alertmanager-kps-alertmanager-0 (2/2 Running),
#         kps-grafana-* (3/3 Running),
#         kps-operator (1/1), kps-kube-state-metrics (1/1),
#         kps-prometheus-node-exporter (1/1).
```

What this gives you:

* Prometheus Operator + a `Prometheus` CR scraping any `ServiceMonitor` /
  `PodMonitor` / `PrometheusRule` in `stayledger-ai`, `observability`,
  and `kube-system`.
* Grafana on **NodePort 30030** — credentials stored in Secret `grafana-admin-credentials`.
  See [grafana-admin-secret.yaml](grafana-admin-secret.yaml) for the current admin-user key.
  **Current admin password is NOT the initial value** — it was rotated on 2026-05-02 (see
  [Runbook: Grafana Password Rotation](#runbook-grafana-password-rotation) below).
* Alertmanager wired with a placeholder `null` receiver — replace before prod.

> ⚠️ **Grafana & Persistent DB — Important behaviour**  
> `GF_SECURITY_ADMIN_PASSWORD` (set from the Kubernetes Secret) **only seeds the admin
> account the very first time** Grafana initialises a fresh SQLite database.  
> Once `grafana.db` exists on the PVC, Grafana ignores the env var for login purposes.
> **Changing the Secret alone does NOT change the admin password.**  
> You must always run `grafana cli admin reset-admin-password` inside the pod as well
> (see runbook below).

---

## 6. Install Loki v3 + Promtail

```powershell
helm upgrade --install loki grafana/loki `
  -n observability `
  -f k8s/observability/loki-values-v3.yaml `
  --timeout 10m

kubectl -n observability wait --for=condition=ready pod -l app.kubernetes.io/name=loki --timeout=5m

helm upgrade --install promtail grafana/promtail `
  -n observability `
  -f k8s/observability/promtail-values.yaml `
  --timeout 10m

kubectl -n observability rollout status ds/promtail --timeout=5m
```

Promtail is configured separately in
[`promtail-values.yaml`](promtail-values.yaml) because the Loki v3 chart
does not deploy a log collector. Its pipeline parses JSON logs, indexes
bounded labels (`tenant_id`, `level`, `service_name`), and keeps
`trace_id`/`span_id` as structured metadata instead of Loki labels.

---

## 7. Install Tempo (single-binary)

```powershell
helm install tempo grafana/tempo `
  -n observability `
  -f k8s/observability/tempo-values.yaml `
  --timeout 10m

kubectl -n observability wait --for=condition=ready pod -l app.kubernetes.io/name=tempo --timeout=5m
```

Same StatefulSet caveat as Loki. The chart prints a deprecation warning
(upstream is moving to `tempo-distributed`); migration is a future task.

---

## 8. Apply plain manifests (OTel, monitors, rules, dashboards)

**Recommended:** run the reconcile script (verify + Helm upgrade + full manifest set):

```powershell
.\scripts\reconcile-observability.ps1           # full reconcile
.\scripts\reconcile-observability.ps1 -VerifyOnly # audit only
.\scripts\reconcile-observability.ps1 -SkipHelm   # manifests only (no chart upgrade)
```

Manual equivalent:

```powershell
kubectl apply -f k8s/observability/otel-collector.yaml
kubectl apply -f k8s/observability/servicemonitor-api.yaml
kubectl apply -f k8s/observability/servicemonitor-datastores.yaml
kubectl apply -f k8s/observability/prometheus-rules.yaml
kubectl apply -f k8s/observability/prometheus-recording-rules.yaml
kubectl apply -f k8s/observability/prometheus-infrastructure-alerts.yaml
kubectl apply -f k8s/observability/stayledger-ai-assistant-alerts.yaml
kubectl apply -f k8s/observability/datastore-exporter-alerts.yaml
kubectl apply -f k8s/observability/metrics-pipeline-alerts.yaml
kubectl apply -f k8s/observability/grafana-dashboard-golden-signals.yaml
kubectl apply -f k8s/observability/grafana-dashboard-llm-cost.yaml
kubectl apply -f k8s/observability/grafana-dashboard-slo.yaml
kubectl apply -f k8s/observability/grafana-dashboard-pricing-booking.yaml
kubectl apply -f k8s/observability/grafana-dashboard-kpi-cost-errors-logs.yaml
kubectl apply -f k8s/observability/rbac.yaml
kubectl apply -f k8s/observability/resource-quotas.yaml
kubectl apply -f k8s/observability/pod-disruption-budgets.yaml
```

| File | Effect |
|---|---|
| [otel-collector.yaml](otel-collector.yaml) | OTLP → Tempo; ServiceMonitor on collector metrics |
| [servicemonitor-api.yaml](servicemonitor-api.yaml) | Scrape `/metrics/prom` on `stayledger-ai-api` |
| [prometheus-rules.yaml](prometheus-rules.yaml) | `stayledger-ai-slo` |
| [stayledger-ai-assistant-alerts.yaml](stayledger-ai-assistant-alerts.yaml) | App alerts (`severity: p1\|p2\|p3`) |
| 5× `grafana-dashboard-*.yaml` | Dashboard ConfigMaps (`grafana_dashboard: "1"`) |

Active index: [README.md](README.md).

---

---

## Runbook: Grafana Password Rotation

> Use this procedure **every time** you need to change the Grafana admin password.
> Patching the Kubernetes Secret alone is **not enough** because the password is
> persisted in `grafana.db` on the PVC and is not re-read from the env var after
> first initialisation.

### Root cause
| Layer | What happens |
|---|---|
| Kubernetes Secret | `grafana-admin-credentials` — provides `GF_SECURITY_ADMIN_PASSWORD` to the pod |
| Grafana init | On first start with a **blank** PVC, Grafana seeds `grafana.db` with the env-var password |
| Subsequent starts | Grafana reads the password **from `grafana.db`**, ignoring the env var |
| Symptom | Secret updated → pod restarted → login still fails with `invalid password` |

### Correct rotation procedure (PowerShell)

```powershell
# 1. Generate a new secure password
$newPw = [Convert]::ToBase64String(
    [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24)
).Replace('=','').Replace('+','-').Replace('/','_')
Write-Host "New password: $newPw"  # save this somewhere safe!

# 2. Update the Kubernetes Secret
kubectl -n observability patch secret grafana-admin-credentials `
  -p "{`"stringData`":{`"admin-password`":`"$newPw`"}}"

# 3. Reset the password inside Grafana's SQLite DB
kubectl -n observability exec deploy/kps-grafana -c grafana -- `
  grafana cli admin reset-admin-password "$newPw"
# expected output: Admin password changed successfully ✔

# 4. Verify
$creds = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:$newPw"))
(Invoke-WebRequest -Uri 'http://10.89.1.40:30030/api/user' `
  -Headers @{ Authorization = "Basic $creds" } -UseBasicParsing).StatusCode
# expected: 200

# 5. Update grafana-admin-secret.yaml to reflect the new password
# (file is in .gitignore — safe to store plaintext locally)
```

> **Note**: Step 3 (`grafana cli`) connects to the same `grafana.db` on the PVC,
> so there is no need to restart the pod. The live Grafana process re-reads the
> hashed password from the DB on the next login attempt.

### Last rotation
| Date | Rotated by | Reason |
|---|---|---|
| 2026-05-02 | Admin (automated) | Initial old password `gEipRU0CB85KzwLY` stopped working after DB was preserved on PVC across pod restarts |

---

## 9. Wire the API to the Collector

Set the OTLP endpoint env var on the API Deployment. The Phase C2 SDK
init is opt-in: it's a no-op until this env var is present.

```powershell
kubectl -n stayledger-ai set env deploy/stayledger-ai-api `
  OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc.cluster.local:4318 `
  OTEL_SERVICE_NAME=stayledger-ai-api

kubectl -n stayledger-ai rollout status deploy/stayledger-ai-api --timeout=180s
```

> If your cluster has a default-deny NetworkPolicy in `stayledger-ai`,
> add an egress rule allowing TCP `4318` to the `observability` namespace.
> Our cluster's existing `allow-api-egress` policy permits all internal
> traffic to be re-evaluated by per-target rules — check before adding.

Verify the SDK is exporting:

```powershell
kubectl -n stayledger-ai logs -l app.kubernetes.io/name=stayledger-ai-api --tail=50 `
  | Select-String "trace_id"
# expect: trace_id values are 32 hex chars (OTel) — NOT the request_id UUID
#         that gets stamped when OTel is unset.
```

---

## 10. Verify end-to-end

### Prometheus — scrape target healthy

```powershell
kubectl -n observability port-forward svc/kps-prometheus 19090:9090
# in another shell:
$t = (Invoke-WebRequest "http://127.0.0.1:19090/api/v1/targets?state=active" `
       -UseBasicParsing).Content | ConvertFrom-Json
$t.data.activeTargets | Where-Object { $_.scrapeUrl -like "*8000/metrics/prom*" } `
  | ForEach-Object { "$($_.scrapeUrl)  health=$($_.health)" }
# expect: both API pods, health=up
```

### Prometheus — alert rules loaded

```powershell
$r = (Invoke-WebRequest "http://127.0.0.1:19090/api/v1/rules" -UseBasicParsing).Content | ConvertFrom-Json
($r.data.groups | ? name -eq "stayledger-ai.slo").rules | Select-Object name
# expect: WebhookHighLatencyP95, WebhookHighErrorRate, LLMCostSpike, RedisDown, WebhookCircuitOpen
```

### Grafana — dashboards visible

```powershell
kubectl -n observability port-forward svc/kps-grafana 13000:80
Start-Process http://localhost:13000          # admin / ChangeMe-Week4!
# expect: folder "StayLedger AI" with five dashboards.
```

Or hit NodePort directly: `http://<node-ip>:30030`.

### Tempo — traces arriving

Generate a trace, then query Tempo by ID:

```powershell
kubectl -n stayledger-ai port-forward svc/stayledger-ai-api 18080:8000
Invoke-WebRequest http://127.0.0.1:18080/readyz -UseBasicParsing | Out-Null

# pull a trace_id from the API logs:
$tid = (kubectl -n stayledger-ai logs -l app.kubernetes.io/name=stayledger-ai-api --tail=20 `
        | Select-String '"trace_id":\s*"([a-f0-9]{32})"' `
        | Select-Object -First 1).Matches[0].Groups[1].Value

kubectl -n observability port-forward svc/tempo 13200:3100
Invoke-WebRequest "http://127.0.0.1:13200/api/traces/$tid" -UseBasicParsing `
  | Select-Object -ExpandProperty StatusCode
# expect: 200
```

### Loki — logs queryable

```powershell
kubectl -n observability port-forward svc/loki 13100:3100
Invoke-WebRequest "http://127.0.0.1:13100/loki/api/v1/labels" -UseBasicParsing `
  | Select-Object -ExpandProperty StatusCode
# expect: 200
```

In Grafana → Explore → Loki, run:

```logql
{namespace="stayledger-ai"} | json | trace_id != ""
```

Click the `trace_id` field on a row → Tempo opens with the span tree.

---

## 11. Day-2 operations

| Task | Command |
|---|---|
| Reload Prometheus config (after editing values) | `helm upgrade kps prometheus-community/kube-prometheus-stack -n observability -f k8s/observability/kube-prometheus-stack-values.yaml` |
| Edit a dashboard in Grafana, then export it back to Git | Save → Share → Export → JSON for sharing externally → paste into the matching `grafana-dashboard-*.yaml` ConfigMap → `kubectl apply -f ...`. |
| Add a new alert | Append to `groups[0].rules` in [`prometheus-rules.yaml`](prometheus-rules.yaml), `kubectl apply`. Operator hot-reloads; verify on `/api/v1/rules`. |
| Rotate Grafana admin password | `kubectl -n observability set env deploy/kps-grafana GF_SECURITY_ADMIN_PASSWORD=<new>` and rollout-restart. Better: switch to a Secret reference in values. |
| Wire Alertmanager to Slack | Edit `alertmanager.config.receivers` in [`kube-prometheus-stack-values.yaml`](kube-prometheus-stack-values.yaml), `helm upgrade`. |
| Resize Loki PV | Delete the StatefulSet (`--cascade=orphan`), edit `observability-loki-pv` capacity + delete/recreate the PVC, restart loki-0. |

---

## 12. Tear-down (reverse order)

```powershell
helm uninstall tempo -n observability
helm uninstall loki  -n observability
helm uninstall kps   -n observability

# PVCs (uninstall does not delete them by default with sidecars in play)
kubectl -n observability delete pvc --all

# PVs are Retain — finalizers may need removal:
foreach ($p in @("observability-prometheus-pv","observability-alertmanager-pv",
                  "observability-grafana-pv","observability-loki-pv","observability-tempo-pv")) {
  kubectl patch pv $p --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
}
kubectl delete -f k8s/observability/storage-pvs.yaml

# Manifests
kubectl delete -f k8s/observability/otel-collector.yaml
kubectl delete -f k8s/observability/servicemonitor-api.yaml
kubectl delete -f k8s/observability/prometheus-rules.yaml
kubectl delete -f k8s/observability/grafana-dashboard-golden-signals.yaml
kubectl delete -f k8s/observability/grafana-dashboard-llm-cost.yaml
kubectl delete -f k8s/observability/grafana-dashboard-pricing-booking.yaml

# Finally
kubectl delete -f k8s/observability/namespace.yaml

# On the node, optionally reclaim disk:
sudo rm -rf /mnt/stayledger-ai/observability
```

Don't forget to unset the API's OTLP endpoint:

```powershell
kubectl -n stayledger-ai set env deploy/stayledger-ai-api `
  OTEL_EXPORTER_OTLP_ENDPOINT- OTEL_SERVICE_NAME-
```

---

## 13. Troubleshooting cheat-sheet

| Symptom | Likely cause | Fix |
|---|---|---|
| PVC stuck `Pending`, `pod has unbound immediate PersistentVolumeClaims` | StorageClass missing or PV `claimRef` doesn't match the actual PVC name | Re-apply [storage-pvs.yaml](storage-pvs.yaml); verify `kubectl get pvc -o jsonpath='{.items[*].metadata.name}'` matches the `claimRef.name` in each PV. |
| PVC `Lost`, PV `Available` but capacity `0` | The previous PVC was deleted but the PV's `claimRef.uid` still points at it | `kubectl edit pv <pv-name>` and remove `spec.claimRef.uid` (and `resourceVersion`). |
| `helm upgrade loki/tempo` fails: `StatefulSet ... is invalid: spec: Forbidden` | StatefulSet specs are immutable except for a few fields | `helm uninstall` then `helm install` (data on PV is preserved). |
| Prometheus target `health=down`, error `context deadline exceeded` | NetworkPolicy in `stayledger-ai` blocks ingress from `observability`, OR API pod CPU saturated | Add `from: namespaceSelector matchLabels: kubernetes.io/metadata.name: observability` to the API ingress NetPol; check `kubectl top pod -n stayledger-ai`. |
| API logs show `trace_id` = request UUID (not 32-hex) | OTel SDK didn't initialize | `OTEL_EXPORTER_OTLP_ENDPOINT` env var missing or unreachable; check `kubectl -n stayledger-ai exec deploy/stayledger-ai-api -- env | findstr OTEL`. |
| Tempo returns 404 on `/api/traces/<id>` | Trace not yet flushed (5s batch) or wrong tenant | Wait 10s and retry; ensure `tempo` chart's `auth_enabled: false`. |
| Grafana dashboard panel shows "No data" | Metric series doesn't exist yet | Generate traffic; if metric uses a relabeled label (e.g. `route="/webhook"`), confirm the API actually served that route. |
| `helm upgrade kps` re-creates PVCs with empty `storageClassName` | `*-values.yaml` missed the `storageClassName: observability-sc` field | Re-check that all four storage stanzas in [`kube-prometheus-stack-values.yaml`](kube-prometheus-stack-values.yaml) (Prometheus, Alertmanager, Grafana, sidecar) include the SC. |

---

## Appendix — file index

| File | Role |
|---|---|
| [`namespace.yaml`](namespace.yaml) | `observability` namespace |
| [`storage-pvs.yaml`](storage-pvs.yaml) | `observability-sc` SC + 5 local PVs with `claimRef` pinning |
| [`kube-prometheus-stack-values.yaml`](kube-prometheus-stack-values.yaml) | Helm values: Prometheus, Grafana (NodePort 30030, Loki+Tempo datasources), Alertmanager |
| [`loki-values-v3.yaml`](loki-values-v3.yaml) | Helm values: Loki v3 single-binary storage/query path |
| [`promtail-values.yaml`](promtail-values.yaml) | Helm values: Promtail DaemonSet, JSON parsing, `tenant_id` label extraction |
| [`tempo-values.yaml`](tempo-values.yaml) | Helm values: Tempo single-binary, OTLP gRPC+HTTP |
| [`otel-collector.yaml`](otel-collector.yaml) | OTel Collector Deployment+Service+ServiceMonitor |
| [`servicemonitor-api.yaml`](servicemonitor-api.yaml) | `ServiceMonitor` → `stayledger-ai-api:/metrics/prom` |
| [`prometheus-rules.yaml`](prometheus-rules.yaml) | 5 SLO alerts (`stayledger-ai.slo` group) |
| [`grafana-dashboard-golden-signals.yaml`](grafana-dashboard-golden-signals.yaml) | RED + saturation dashboard (ConfigMap) |
| [`grafana-dashboard-llm-cost.yaml`](grafana-dashboard-llm-cost.yaml) | LLM token rate, cache hit, $/hr (ConfigMap) |
| [`grafana-dashboard-pricing-booking.yaml`](grafana-dashboard-pricing-booking.yaml) | Pricing source, n8n outcomes, booking funnel (ConfigMap) |

For the **why** behind each file (alert PromQL choices, dashboard panel
selection, `/webhook` routing, etc.) see
[`docs/WEEK4_OBSERVABILITY_AND_ASYNC.md`](../../docs/WEEK4_OBSERVABILITY_AND_ASYNC.md).
