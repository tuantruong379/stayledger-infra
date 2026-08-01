# Kubernetes HA Migration Plan — 2026-04-29

This document outlines the roadmap to make the multi-tenant Kubernetes deployment production-ready with high availability.

## Current State (Single-Replica)

| Component | Replicas | Storage | Failover | Risk Level |
|-----------|----------|---------|----------|-----------|
| hotel-assistant-api | 3 (HPA: 2-10) | Local PV | Auto (via HPA) | **LOW** ✓ |
| hotel-assistant-channel-worker | 1 | Shared PVC | Manual | **MEDIUM** ⚠️ |
| hotel-assistant-webhook-worker | 1 | Shared PVC | Manual | **MEDIUM** ⚠️ |
| Redis | 1 | Local PV (RWO) | Manual | **HIGH** 🔴 |
| Postgres (workflow metadata) | 1 | Local PV (RWO) | Manual | **HIGH** 🔴 |
| Workflow engine | 1 | Local PV (RWO) | Manual | **HIGH** 🔴 |

## Phase 1: Workers HA (Near-term, 2-4 weeks)

### Channel Worker

**Goal:** Scale from 1 to 2-3 replicas without data loss.

**Current Issue:** Workers share a PVC (RWO), which allows only one pod to mount at a time.

**Solution:**
```yaml
# Option A: Keep RWO, use PDB to prevent simultaneous pod drain
# — Implicit: only one pod runs at a time
spec:
  replicas: 1  # Keep as-is, add second node-local storage replica

# Option B: Migrate to RWX storage (NFS, GlusterFS, Ceph)
# — Allows multiple pods to mount the same PVC
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
  # ... deploy on multiple nodes
```

**Recommended:** **Option B (RWX)** for true HA.

**Steps:**
1. Set up NFS server (or managed NFS service) with redundancy
2. Create StorageClass with `accessModes: [ReadWriteMany]`
3. Migrate PVCs from RWO to RWX
4. Scale channel-worker replicas to 2-3
5. Test drain + failover scenarios

**Timeline:** 1-2 weeks (infrastructure + migration)

---

### Webhook Worker

**Same as channel worker.** If `WEBHOOK_ASYNC_QUEUE=1`, webhook worker benefits from RWX migration too.

---

## Phase 2: Redis HA (High Priority, 3-6 weeks)

### Current State
- Single pod, single storage node
- If node dies → complete cache loss + performance degradation
- Multi-tenant cache keys (e.g., `memory:tenant-id:*`) all lost

### Solution: Redis Sentinel

**Architecture:**
```
Redis Master (pod-0)
Redis Replica (pod-1)  — polls Master, replicas data
Redis Replica (pod-2)  — polls Master, replicas data
  ↓
Sentinel (pod-A)
Sentinel (pod-B)       — monitors Master + triggers failover
Sentinel (pod-C)
```

**Benefits:**
- Automatic failover when Master becomes unavailable
- 3-replica read scaling (distribute read load)
- Minimal reconfiguration needed on client side (use Sentinel DNS)

**Implementation:**
1. Use `redis-ha` Helm chart (community-maintained)
2. Configure Sentinel for 3-node cluster
3. Update `REDIS_URL` in API ConfigMap to use Sentinel service
4. Test failover by killing the Master pod

**Timeline:** 2-3 weeks (setup + testing + cutover)

**Migration Path:**
```bash
# Phase 2a: Deploy Sentinel cluster alongside single-node Redis
# Phase 2b: Test failover in non-production environment
# Phase 2c: Migrate client configs (REDIS_URL) to Sentinel endpoint
# Phase 2d: Decommission old single-node Redis
```

---

## Phase 3: Postgres HA (High Priority, 4-8 weeks)

### Current State
- Single pod, single storage node
- Workflow metadata + booking/pricing workflow state stored here
- Loss = complete workflow cluster data loss + booking history

### Solution: Patroni (PostgreSQL Cluster Manager)

**Architecture:**
```
Postgres Master (pod-0)
Postgres Replica (pod-1)  — streams WAL from Master
Postgres Replica (pod-2)  — streams WAL from Master
  ↓
Patroni (pod-0)
Patroni (pod-1)           — DCS (Distributed Consensus) via etcd/consul
Patroni (pod-2)           — coordinates failover
```

**Benefits:**
- Automatic failover (leader election via Patroni)
- Read replicas offload SELECT queries
- Minimal RPO (Recovery Point Objective) via streaming replication

**Implementation:**
1. Deploy etcd cluster (3+ nodes, for DCS)
2. Use `postgres-operator` Helm chart (Zalando's PG Operator recommended)
3. Configure 3-node Patroni + 2 replicas
4. Migrate workflow engine to new cluster (or in-place upgrade)

**Timeline:** 3-4 weeks (setup + migration + validation)

**Gotchas:**
- etcd cluster must be highly available (use managed etcd or self-hosted 3+ nodes)
- Postgres version pins (upgrade path matters)
- Backup strategy (WAL archiving to S3 / GCS)

---

## Phase 4: Workflow Queue Mode (Long-term, 6-12 weeks)

### Current State
- Single web pod (runs UI + webhook listener)
- If pod dies → no workflow executions until restart
- executions are queued in Postgres, but no executor is running

### Solution: Workflow Queue Mode

**Architecture:**
```
Workflow Web Pod (replicas: 2-3)  — UI + webhook listener + queue manager
  ↓
Workflow Worker Pods (replicas: 3-10) — execute workflows, scale independently
  ↓
Redis Queue (HA cluster from Phase 2)
```

**Benefits:**
- Web pod is stateless, scales horizontally
- Worker pool can scale based on queue depth (independent from UI)
- No data loss on pod eviction (work persists in Redis queue)

**Implementation:**
1. Enable workflow queue mode environment variables
2. Set Redis Queue backend to the HA Redis cluster (Phase 2)
3. Deploy worker Deployment alongside workflow web
4. Configure KEDA or custom HPA on worker queue depth
5. Tune worker concurrency based on load tests

**Timeline:** 2-3 weeks (after Phase 2 Redis is ready)

**Dependency:** Phase 2 (Redis HA) must be complete first.

---

## Phase 5: Multi-Node Storage (Ongoing)

### Current State
- Local PV on single node (`hkk8s-hub-master`)
- Fixed affinity blocks any node-agnostic deployment

### Solution: Distributed Storage

**Options:**

| Option | Pros | Cons | Timeline |
|--------|------|------|----------|
| **NFS** | Simple setup, wide support | Single point of failure, performance | 1 week |
| **Ceph** | HA out-of-box, mature | Complex ops, resource-heavy | 4+ weeks |
| **GlusterFS** | Good HA balance | Less common in Kubernetes | 3 weeks |
| **Managed (e.g., Azure AFS, AWS EFS)** | Hands-off HA, pay-per-use | Cloud-locked, latency | 1 week |

**Recommended:** **NFS + HA setup** (2-3 week effort, familiar ops model).

### Setup NFS HA:
```bash
# NFS Server (Ubuntu VM + NFS kernel server)
# — Configure exports with `no_root_squash` for Kubernetes PVC
# — Set up automated snapshots (e.g., ZFS) for point-in-time recovery

# HA NFS Layer (optional):
# — Use Pacemaker + Virtual IP (VIP) to auto-failover NFS service
# — or use managed NFS (EFS, AFS) from cloud provider
```

---

## Dependency Graph

```
Phase 1 (Workers RWX)
    ↓
Phase 2 (Redis HA)
    ↓
Phase 3 (Postgres HA)
    ↓
Phase 4 (workflow queue mode) ← depends on Redis HA
    ↓
Phase 5 (Distributed Storage) ← enables Phases 1-4
```

**Critical path:** Phases 2 & 3 are highest priority (data tier). Phase 1 & 4 depend on Phase 2.

---

## Testing Strategy

### Failure Scenarios to Validate

After each phase, test these scenarios:

1. **Pod Eviction:** Drain a node → pods reschedule → verify no data loss
2. **Component Restart:** Kill pod → Kubernetes restarts → verify state recovery
3. **Cascading Failure:** Kill master (Redis/Postgres) → verify automatic failover
4. **Network Partition:** Isolate pod from cluster → verify recovery
5. **Load Test:** Ramp traffic → verify autoscaling + no drops
6. **Backup Restore:** Test restore from backup → verify correctness

### Test Environment

- Spin up dev cluster (3 nodes minimum) → mirror production setup
- Use Chaos Engineering tools (Gremlin, LitmusChaos) to inject failures
- Document test results + expected recovery times

---

## Rollout Timeline (Realistic)

| Phase | Duration | Risk | Go-Live |
|-------|----------|------|---------|
| Phase 1 (Workers RWX) | 2-4 weeks | LOW | Week 4 |
| Phase 2 (Redis HA) | 2-3 weeks | MEDIUM | Week 7 |
| Phase 3 (Postgres HA) | 3-4 weeks | MEDIUM | Week 11 |
| Phase 4 (workflow queue) | 2-3 weeks | MEDIUM | Week 14 |
| Phase 5 (Storage) | Ongoing | LOW | Week 15+ |

**Total: 12-15 weeks to full HA (3-4 months).**

---

## Immediate Actions (This Week)

1. ✅ Fix node affinity (use labels, not hardcoded hostnames) — **DONE**
2. ✅ Add webhook-worker network policies — **DONE**
3. ✅ Add HPA for workers — **DONE**
4. Provision NFS storage infrastructure (or decide: cloud-managed vs self-hosted)
5. Start Phase 1 design (RWX migration plan)
6. Create test environment (3-node cluster) for failover validation

---

## Monitoring & Alerts

Once HA setup is in place, configure:

- **PVC usage alerts** (% full, predict when full)
- **Redis node health** (liveness check, replication lag)
- **Postgres replication lag** (replication > 10MB = alert)
- **workflow queue depth** (queue backlog > threshold = scale workers)
- **Node drain events** (track graceful vs ungraceful evictions)

Use Prometheus + Grafana (already deployed in `k8s/observability/`).

---

## References

- [Redis Helm Chart (Bitnami)](https://github.com/bitnami/charts/tree/master/bitnami/redis)
- [Redis Sentinel Setup](https://redis.io/topics/sentinel)
- [Postgres Operator (Zalando)](https://github.com/zalando/postgres-operator)
- Workflow Queue Mode documentation (vendor-specific)
- [Kubernetes Local Storage Best Practices](https://kubernetes.io/docs/concepts/storage/volumes/#local)
- [LitmusChaos for Failure Testing](https://litmuschaos.io/)
