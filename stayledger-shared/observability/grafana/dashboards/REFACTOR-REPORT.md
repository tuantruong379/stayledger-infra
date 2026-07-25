# Grafana Dashboard Refactor - PMS-First Structure (2026-06-23)

Scope: `stayledger-infra/stayledger-shared/observability/grafana/dashboards/`. Goal: make Grafana useful for **PMS production/staging readiness**; defer AI dashboards out of the readiness path. No product/business logic touched.

## A. Summary

- **Dashboards before:** 12 (7 in `StayLedger PMS`, 5 in `StayLedger AI`)
- **Dashboards after:** 12 (none deleted) - **6 production** in `StayLedger PMS`, **6 deferred** in `StayLedger Internal`
- **Kept in PMS production:** Executive Overview, API Performance, Booking Lifecycle, Database & PgBouncer, Kubernetes, k6 Load Test
- **Moved to Internal/Deferred:** PMS AI Observability + 5 AI Assistant dashboards (Golden Signals, SLO & Error Budget, Tokens/Cost/Errors/Logs, LLM Cost & Cache, Pricing & Booking Funnel)
- **Removed:** none (conservative; the PMS set is well-factored and AI dashboards still have active alerts)
- **Panels removed/moved/deferred:** 0 panels physically removed. Whole **AI Observability dashboard** re-foldered to Internal; within it, the Channel Manager (4) and Overage Billing (4) blocks are flagged as split candidates (deferred - see D).
- **k6 metric validation:** **PASS** - pipeline wired, core names match (see C).

## B. Final structure

**Folder `StayLedger PMS`** (tags: `stayledger`, `pms`, `production-readiness`, + per-dash):
1. `01 - PMS Executive Overview`  (uid `stayledger-executive`) - +dashboard links to 02-06
2. `02 - PMS API Performance`     (uid `stayledger-api-perf`)
3. `03 - PMS Booking Lifecycle`   (uid `stayledger-booking`)
4. `04 - PMS Database & PgBouncer`(uid `stayledger-database`)
5. `05 - PMS Kubernetes`          (uid `stayledger-k8s`)
6. `06 - PMS k6 Load Test`        (uid `stayledger-k6`)

**Folder `StayLedger Internal`** (tags: `stayledger`, `internal`, `deferred`, `ai`[, `assistant`]):
- `PMS AI Observability` (uid `stayledger-ai`)
- `AI Assistant - Golden Signals` (uid `hotel-golden`)
- `AI Assistant - SLO & Error Budget` (uid `hotel-slo`)
- `AI Assistant - Tokens, Cost, Errors & Logs` (uid `hotel-kpi-cost-errors-logs`)
- `AI Assistant - LLM Cost & Cache` (uid `hotel-llm-cost`)
- `AI Assistant - Pricing & Booking Funnel` (uid `hotel-pricing-booking`)

Folder is driven by the ConfigMap `grafana_folder` annotation (sidecar `folderAnnotation`), which overrides on-disk path - confirmed by the pre-existing setup (dir `stayledger-ai-assistant/` already mapped to folder `StayLedger AI`). UIDs preserved → existing links/bookmarks/alert annotations keep working.

## C. Key changes

1. **Folder re-scoping** - `grafana_folder` annotation: 6 production → `StayLedger PMS`, 6 AI → `StayLedger Internal`.
2. **Naming** - production dashboards renamed `01`-`06 - PMS …` for incident-workflow sort order; AI titles normalized to `AI Assistant - …`.
3. **Tags** - standardized (`production-readiness` on PMS; `internal`/`deferred` on AI) for folder-independent filtering.
4. **Executive Overview links** - added a dashboard `links` array (explicit links to 02-06 by uid + a `pms`-tag dropdown) so it is the curated entry point that drills down.
5. **Encoding** - replaced all em-dash `-`/en-dash `-` with ASCII `-` across all 12 files (titles + panel text). Verified: 0 `-` remain, all files UTF-8/ASCII.
6. **k6 validation** - queried Prometheus (`/api/v1/label/__name__/values`): **24 `k6_*` series present**, remote-write pipeline wired. Dashboard's core names **match** (`k6_http_req_duration_seconds`, `k6_http_reqs_total`, `k6_http_req_failed_rate`, `k6_iteration_duration_seconds`, `k6_checks_rate`, `k6_vus`, `k6_*_success_rate`, `k6_booking_lifecycle_ms`). Scenario-conditional names (`k6_bookings_created_total`, `k6_write_error_rate`, `k6_inventory_conflict_rate`, `k6_system_5xx_rate`, `k6_ai_chat_duration_ms`) are correct but populate only when write/ai scenarios run with `--out experimental-prometheus-rw`. The alarming "verify metric names" warning panel was **downgraded** to a concise validated "Metric source" note.
7. **Traffic guards** - audited every division in the 6 PMS dashboards: **all error-rate panels already use `clamp_min`** safe division (executive 3/3, booking 5/5, database 1/1, kubernetes 5/5; api-performance's only error-rate panel guarded - its other "divisions" were false positives from `/` inside route label values). **No changes required.**

## D. Risk / notes (not done - deliberate)

- **No panel deletions.** The PMS dashboards are well-factored and each panel maps to an alert or a clear triage action; the user direction was "do not remove blindly". AI dashboards retain active alerts (`AiErrorRateHigh`, `AiTokenQuota*`) so deleting them would orphan alert links - re-foldering is safer.
- **Executive AI KPIs kept.** Executive Overview still shows 4-5 high-level PMS-AI stat panels (AI error rate, AI requests/tokens today, top-3 quota). They are 1-line stats tied to live alerts; removing them is optional and was not done to avoid churn. Flagged for a future pass if AI is fully descoped.
- **AI Observability split deferred.** Recommended (future): extract Channel Manager (OTA sync - not AI) to an Integrations dashboard and Overage Billing to a billing/executive view, leaving a focused AI dashboard. Not done because the whole dashboard is now Internal/deferred this phase.
- **AI cost dedup deferred.** `kpi-cost-errors-logs` and `llm-cost` overlap (Est cost $/hr, Cost by tenant, Tokens by direction); `golden-signals` and `slo` share 3 identical tenant panels. Merge/dedup deferred (Internal scope this phase).
- **Variables.** Production dashboards use `constant` template vars (`api_job`, `namespace`, `db`, `postgres_job`) - functional and env-pinned to `stayledger-staging`. A true `$datasource`/`$env` variable set would require rewiring every panel's `datasource`/label selectors (~140 panels) and risks breakage; deferred per the task's "do not force them incorrectly" guidance. Recommended as a separate, tested pass.

## E. Validation

```
# YAML + embedded JSON parse (12/12)
python -c "import yaml,json,glob; [json.loads(yaml.safe_load(open(p,encoding='utf-8'))['data'][[k for k in yaml.safe_load(open(p,encoding='utf-8'))['data'] if k.endswith('.json')][0]]) for p in glob.glob('**/*.yaml',recursive=True)]"
  -> 12 valid / 0 invalid

# Encoding
grep -rlF "-" .            -> none
file -i */*.yaml           -> all charset=utf-8 / us-ascii

# Folders
grep -rh "grafana_folder:" -> 6 "StayLedger PMS", 6 "StayLedger Internal"

# k6 metrics in Prometheus
curl .../api/v1/label/__name__/values  -> 24 k6_* series present (pipeline wired)
```

Acceptance: PMS production scope reduced to 6 dashboards; AI moved to Internal/Deferred (not deleted); names/folders/tags consistent; Executive Overview curated + links to detail dashboards; API/Booking/DB/k8s dashboards retain their triage panels; k6 metric names validated (warning downgraded); all error-rate panels use safe division; JSON valid; encoding fixed.
