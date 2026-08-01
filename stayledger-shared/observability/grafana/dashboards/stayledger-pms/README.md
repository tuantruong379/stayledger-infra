# StayLedger PMS Grafana dashboards

Folder in Grafana: `StayLedger PMS` (production readiness). The folder is set by the
`grafana_folder` ConfigMap annotation (the sidecar's `folderAnnotation`), which takes
precedence over the on-disk directory - so a file's location does not decide its folder.

This phase scopes the **PMS production-readiness** set to six dashboards, numbered
`01`-`06` so they sort in incident-workflow order. Prefer starting from **01 - Executive
Overview**, then drill into API, booking/payment, database, Kubernetes, or k6 depending
on the failing signal (Executive Overview has dashboard links to each).

Each dashboard has an on-screen panel titled **Purpose / When No data is OK** so operators
can tell expected empty panels from real scrape failures without leaving Grafana.

**Why keep six (not consolidate further):** UIDs (`stayledger-executive` ... `stayledger-k6`)
are linked from Executive, gate5 evidence, and alert-to-dashboard maps. Merging would break
bookmarks and mix drill-down responsibilities. `06` stays in this folder but is load-window
only (expected empty day-to-day).

AI dashboards (PMS AI Observability + the five AI Assistant dashboards) are **deferred**
in this phase and live in the `StayLedger Internal` Grafana folder (tags
`internal`, `deferred`). They are not part of the PMS go-live readiness path. They were
not deleted - only re-foldered/tagged.

## Go-live glance checklist

1. Open **01 Executive** - uptime green, RPS present, latency acceptable, unhealthy pods = 0.
2. If latency/errors - drill **02 API** (slow routes / 5xx).
3. If booking/payment volume wrong - drill **03** PMS booking/payment section (not only BE funnel).
4. If write latency / connection alerts - **04 Database**.
5. If restarts / node pressure - **05 Kubernetes** (confirm `$namespace`).
6. Open **06 k6** only during or right after a remote-write load test.

## Production dashboards (folder: StayLedger PMS)

| Dashboard (file) | Grafana title | Purpose | Expected empty / No data | Primary metrics |
|-----------|------|---------|--------------------------|-----------------|
| `executive-overview.yaml` | `01 - PMS Executive Overview` | First screen for go-live and incidents. Roll-up + links to 02-06. | Error-rate No data with healthy RPS usually means zero 5xx (good). | `up`, `http_requests_total`, `http_request_duration_ms_bucket`, `booking_operations_total`, `payment_operations_total`, `pg_stat_activity_count`, `redis_memory_*`, `kube_pod_status_phase` |
| `api-performance.yaml` | `02 - PMS API Performance` | Route-level triage: slow routes, 5xx, 429, auth latency. | 5xx / 429 No data with traffic = healthy. | `http_requests_total`, `http_request_duration_ms_bucket` |
| `booking-lifecycle.yaml` | `03 - PMS Booking Lifecycle` | PMS booking/payment ops + public Booking Engine funnel + money-compare note. | BE funnel 0/No data without public BE traffic is OK (canary uses PMS ops). Money-compare chart empty until counter ships. | `booking_operations_*`, `payment_operations_*`, `booking_engine_*` |
| `database.yaml` | `04 - PMS Database & PgBouncer` | Postgres pressure: connections, cache, tx/row rates, seq scans. | Table size / PgBouncer empty = exporter/scrape gap, not proof API is down. | `pg_stat_*`, `pg_settings_max_connections`, `pg_relation_size`, `pgbouncer_pools_*` |
| `kubernetes.yaml` | `05 - PMS Kubernetes` | Pods, restarts, resources, PVC, node pressure, HPA. | CPU throttle / PVC / HPA empty if labels/`$namespace`/HPA missing. | `kube_*`, `container_*`, `kubelet_volume_stats_*`, `node_filesystem_*` |
| `k6-load-test.yaml` | `06 - PMS k6 Load Test` | Load-test window only (remote write). | **Expected empty** outside k6 runs with `--out experimental-prometheus-rw`. | `k6_*` |

## Deferred dashboards (folder: StayLedger Internal)

| Dashboard (file) | Grafana title | Note |
|---|---|---|
| `ai-observability.yaml` | `PMS AI Observability` | PMS AI features (chat, RAG, metering, quota, automation) + Channel Manager + overage billing panels. Deferred from PMS go-live; candidate to split (Channel Manager -> Integrations, overage -> billing). |
| `../stayledger-ai-assistant/golden-signals.yaml` | `AI Assistant - Golden Signals` | Standalone AI assistant service (different metrics namespace than PMS). |
| `../stayledger-ai-assistant/slo.yaml` | `AI Assistant - SLO & Error Budget` | Duplicates 3 tenant panels with golden-signals (dedup candidate). |
| `../stayledger-ai-assistant/kpi-cost-errors-logs.yaml` | `AI Assistant - Tokens, Cost, Errors & Logs` | Overlaps llm-cost (merge candidate). |
| `../stayledger-ai-assistant/llm-cost.yaml` | `AI Assistant - LLM Cost & Cache` | Overlaps kpi-cost-errors-logs (merge candidate). |
| `../stayledger-ai-assistant/pricing-booking.yaml` | `AI Assistant - Pricing & Booking Funnel` | AI-driven funnel; distinct. |

## Important "no data" cases

- `k6-load-test.yaml` is expected to be empty outside load tests.
- PgBouncer panels are expected to be empty until `pgbouncer-exporter` and its Prometheus scrape job are enabled.
- Booking/payment panels are empty when there was no booking/payment traffic in the selected time range.
- AI quota panels are empty until quota usage is emitted by `AiQuotaService`.
- API panels are empty if `METRICS_ENABLED=false` or Prometheus cannot scrape `stayledger-api` at `/api/metrics`.

## Alert coverage

Current PMS alerts live in `stayledger-shared/observability/alerting/stayledger-rules.yaml` and cover:

| Alert | Dashboard to open | Meaning |
|-------|-------------------|---------|
| `ApiScrapeDown` | Executive Overview | Prometheus cannot scrape `stayledger-api` at `/api/metrics`; API or metrics path may be down. |
| `ApiErrorRateHigh` | API Performance | 5xx ratio is above 1% while traffic is present. |
| `ApiReadP95LatencyHigh` | API Performance / Database | GET p95 latency is above 800 ms for 10 minutes. |
| `ApiWriteP99LatencyHigh` | API Performance / Database | POST p99 latency is above 4 seconds for 5 minutes. |
| `AuthLatencyHigh` | API Performance | `/api/auth/login` p95 latency is above 1 second. |
| `BookingFailureRateHigh` | Booking Lifecycle | Booking errors exceed 2% of created bookings. |
| `PaymentFailureRateHigh` | Booking Lifecycle | Payment errors exceed 2% of payment operations. |
| `BookingEngineFailureRateHigh` | Booking Lifecycle | Booking engine errors exceed 2% of booking-engine traffic. |
| `BookingEngineCreateP95LatencyHigh` | Booking Lifecycle | Booking engine create p95 latency is above 2.5 seconds. |
| `BookingEngineInventoryConflictHigh` | Booking Lifecycle | Booking engine inventory conflicts exceed 10% of create traffic. |
| `AiErrorRateHigh` | AI Observability | AI error ratio is above 3% while AI traffic is present. |
| `AiP95LatencyHigh` | AI Observability | AI p95 latency is above 5 seconds. |
| `AiQuotaBlocksHigh` | AI Observability | AI chat 429 quota blocks elevated (replaces removed AiTokenQuota* max-across-properties alerts). |
| `StayLedgerAIQuotaNearExhaustion` | AI Observability | Per-property quota above 90% (excludes capability_* fixtures). |
| `PostgresConnectionHigh` | Database & PgBouncer | PostgreSQL connection utilization is above 80%. |
| `PgBouncerClientsWaiting` | Database & PgBouncer | PgBouncer has waiting clients. |
| `RedisMemoryHigh` | Executive / Kubernetes | Redis maxmemory utilization is above 85%. |
| `PodCrashLooping`, `PodOOMKilled`, `NodeDiskHigh` | Kubernetes Infrastructure | Runtime infrastructure is unstable or near capacity. |

## Threshold intent

- API 5xx above 1% is critical because it is user-visible.
- Read p95 above 800 ms is warning; write p99 above 4 s is critical because writes block operations and usually correlate with database pressure.
- Booking/payment failure above 2% is critical because it directly affects revenue workflows.
- Booking-engine failure above 2% is critical for public booking conversion; inventory conflict above 10% is warning because it may reflect stale quotes or legitimate sell-out pressure rather than server failure.
- AI error above 3% is warning because AI features degrade before core PMS is down.
- Redis memory above 85%, Postgres connections above 80%, and PVC/disk above 80-85% are early capacity warnings.
