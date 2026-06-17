# StayLedger PMS Grafana dashboards

Folder in Grafana: `StayLedger PMS`.

These dashboards are split by incident workflow. Prefer starting from **Executive Overview**, then drill into API, booking/payment, AI, database, or Kubernetes depending on the failing signal.

## Dashboard ownership

| Dashboard | Purpose | Primary metrics |
|-----------|---------|-----------------|
| `executive-overview.yaml` | First screen for go-live and incidents. Shows uptime, traffic, errors, latency, AI quota, database connections, Redis memory, and bad pod phases. | `up`, `http_requests_total`, `http_request_duration_ms_bucket`, `ai_*`, `booking_operations_total`, `payment_operations_total`, `pg_stat_activity_count`, `redis_memory_*`, `kube_pod_status_phase` |
| `api-performance.yaml` | Route-level API triage. Use it to find slow routes, 5xx routes, rate limits, and auth latency. | `http_requests_total`, `http_request_duration_ms_bucket` |
| `booking-lifecycle.yaml` | Business workflow health. Shows booking creation rate, confirm rate, payment success, booking duration, booking-engine funnel health, and failure breakdown. | `booking_operations_total`, `booking_errors_total`, `booking_lifecycle_duration_ms_bucket`, `payment_operations_total`, `payment_errors_total`, `booking_engine_*` |
| `ai-observability.yaml` | PMS AI features: chat, RAG, metering, quota, daily summaries, revenue recommendations, automation, and security/ops signals. | `ai_requests_total`, `ai_errors_total`, `ai_request_duration_ms_bucket`, `ai_tokens_total`, `ai_cost_estimated_total`, `ai_quota_usage_percent`, `ai_rag_*`, `ai_automation_*` |
| `database.yaml` | PostgreSQL and PgBouncer health. Use it for connection pressure, cache hit ratio, deadlocks, transaction/row rates, table sizes, and pool wait. | `pg_stat_*`, `pg_settings_max_connections`, `pg_relation_size`, `pgbouncer_pools_*` |
| `kubernetes.yaml` | Runtime infrastructure health. Shows bad pod phases, restarts, CPU/memory saturation, throttling, PVC usage, node pressure, and node disk usage. | `kube_*`, `container_*`, `kubelet_volume_stats_*`, `node_filesystem_*` |
| `k6-load-test.yaml` | Load-test only. It will be empty unless k6 remote write is running. | `k6_*` |

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
