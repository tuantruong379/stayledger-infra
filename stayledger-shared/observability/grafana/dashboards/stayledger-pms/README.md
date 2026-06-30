# StayLedger PMS Grafana dashboards

Folder in Grafana: `StayLedger PMS` (production readiness). The folder is set by the
`grafana_folder` ConfigMap annotation (the sidecar's `folderAnnotation`), which takes
precedence over the on-disk directory - so a file's location does not decide its folder.

This phase scopes the **PMS production-readiness** set to six dashboards, numbered
`01`-`06` so they sort in incident-workflow order. Prefer starting from **01 - Executive
Overview**, then drill into API, booking/payment, database, Kubernetes, or k6 depending
on the failing signal (Executive Overview has dashboard links to each).

AI dashboards (PMS AI Observability + the five AI Assistant dashboards) are **deferred**
in this phase and live in the `StayLedger Internal` Grafana folder (tags
`internal`, `deferred`). They are not part of the PMS go-live readiness path. They were
not deleted - only re-foldered/tagged.

## Production dashboards (folder: StayLedger PMS)

| Dashboard (file) | Grafana title | Purpose | Primary metrics |
|-----------|------|---------|-----------------|
| `executive-overview.yaml` | `01 - PMS Executive Overview` | First screen for go-live and incidents. Curated roll-up: uptime, traffic, errors, latency, booking/payment, DB connections, Redis memory, bad pod phases. Links out to 02-06. | `up`, `http_requests_total`, `http_request_duration_ms_bucket`, `booking_operations_total`, `payment_operations_total`, `pg_stat_activity_count`, `redis_memory_*`, `kube_pod_status_phase` |
| `api-performance.yaml` | `02 - PMS API Performance` | Route-level API triage. Find slow routes, 5xx routes, rate limits, and auth latency. | `http_requests_total`, `http_request_duration_ms_bucket` |
| `booking-lifecycle.yaml` | `03 - PMS Booking Lifecycle` | Business workflow health: booking creation/confirm rate, payment success, booking duration, booking-engine funnel, failure breakdown. | `booking_operations_total`, `booking_errors_total`, `booking_lifecycle_duration_ms_bucket`, `payment_operations_total`, `payment_errors_total`, `booking_engine_*` |
| `database.yaml` | `04 - PMS Database & PgBouncer` | PostgreSQL/PgBouncer health: connection pressure, cache hit ratio, deadlocks, transaction/row rates, table sizes, pool wait. | `pg_stat_*`, `pg_settings_max_connections`, `pg_relation_size`, `pgbouncer_pools_*` |
| `kubernetes.yaml` | `05 - PMS Kubernetes` | Runtime infra health: bad pod phases, restarts, CPU/memory saturation, throttling, PVC usage, node pressure. | `kube_*`, `container_*`, `kubelet_volume_stats_*`, `node_filesystem_*` |
| `k6-load-test.yaml` | `06 - PMS k6 Load Test` | Staging/go-live load-test results. Empty unless k6 runs with `--out experimental-prometheus-rw`. Core `k6_*` metric names validated against Prometheus. | `k6_*` |

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
| `AiTokenQuotaWarning` / `AiTokenQuotaCritical` | AI Observability | A property is above 80% / 95% of token quota. |
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
