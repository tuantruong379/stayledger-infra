#!/usr/bin/env bash
# Production promotion r64: release/1.7.22 @ dcebc4c (+ PMS off-node backup image fix).
# Prepared 2026-09-27 from read-only checks of production; run by an operator.
#
#   bash stayledger-ai-assistant-api/production/promote-r64.sh          # from the stayledger-infra root
#
# Stops at the first failure. Every kubectl call names --context stayledger explicitly.
set -euo pipefail
export MSYS_NO_PATHCONV=1

CTX=stayledger
NS=stayledger-ai-assistant
IMG=putin111/stayledger-ai-assistant-api@sha256:8d126bfe3f27c9f759bc940731f81bcdea42af4c50abb4feff435863baa75e83
K="kubectl --context $CTX -n $NS"

step() { printf '\n=== %s\n' "$*"; }

step "0. preflight: context reachable, api image before, migration Job not already present"
$K get deploy stayledger-ai-assistant-api -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
if $K get job alembic-upgrade-r64 >/dev/null 2>&1; then
  echo "alembic-upgrade-r64 already exists -- inspect it ($K logs job/alembic-upgrade-r64) before re-running"; exit 1
fi

step "1. migrations 0095 -> 0098 (backs up tenant_runtime_config.llm first)"
kubectl --context "$CTX" apply -f stayledger-ai-assistant-api/production/patches/alembic-upgrade-r64.job.yaml
$K wait --for=condition=complete job/alembic-upgrade-r64 --timeout=900s || {
  $K logs job/alembic-upgrade-r64 --tail=80; echo "migration failed -- nothing else was changed"; exit 1; }
$K logs job/alembic-upgrade-r64 --tail=20

step "2. roll the five Deployments to $IMG (scoped; apply -k is rejected on the postgres PV path)"
for d in api channel-worker kb-embed-worker metrics-aggregator webhook-worker; do
  $K set image "deploy/stayledger-ai-assistant-$d" "$d=$IMG"
done
for d in api channel-worker kb-embed-worker metrics-aggregator webhook-worker; do
  $K rollout status "deploy/stayledger-ai-assistant-$d" --timeout=300s
done

step "3. CronJobs rag-eval and kb-retention to the same image (set image: the git rag-eval file adds args live does not have)"
$K set image cronjob/rag-eval "rag-eval=$IMG"
$K set image cronjob/kb-retention "kb-retention=$IMG"

step "4. verify"
$K get pods -l app.kubernetes.io/part-of=stayledger-ai-assistant -o wide | grep -v Completed || true
$K exec deploy/stayledger-ai-assistant-api -- python3 -c \
  "import urllib.request as u; print('readyz', u.urlopen('http://127.0.0.1:8000/readyz', timeout=10).status)"
echo "error lines in api logs since rollout: $($K logs deploy/stayledger-ai-assistant-api --since=5m | grep -ciE '"level": ?"(error|critical)"|Traceback' || true)"

step "5. PMS off-node backup image (stayledger namespace)"
kubectl --context "$CTX" apply -f stayledger-shared/datastores/production/postgres-backup-offnode-cronjob.yaml
kubectl --context "$CTX" -n stayledger create job "pg-offnode-verify-$(date +%Y%m%d%H%M)" --from=cronjob/stayledger-postgres-backup-offnode
echo "watch it: kubectl --context $CTX -n stayledger get jobs | grep pg-offnode-verify"

step "done -- commit the prepared stayledger-infra changes (production overlay notes/digests, r64 Job, backup CronJob)"
