#!/usr/bin/env bash
# Isolated restore drill: newest off-node dump -> throwaway Postgres inside a Job -> counts + timings,
# then the same counts read (read-only) from the live database for comparison.
#
#   bash scripts/restore-drill.sh staging pms | staging ai | production pms | production ai
set -euo pipefail
export MSYS_NO_PATHCONV=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ENV=${1:?staging|production}; DB=${2:?pms|ai}

case "$ENV" in
  staging)    CTX=HK-HUB-Cluster; PMS_NS=stayledger-staging; PMS_DB=stayledger_staging ;;
  production) CTX=stayledger;     PMS_NS=stayledger;         PMS_DB=stayledger ;;
  *) echo "bad env"; exit 2 ;;
esac
case "$DB" in
  pms)
    NS=$PMS_NS; LABEL=stayledger-restore-drill; PREFIX="stayledger/${ENV}/postgres/"; PATTERN="stayledger_"
    TABLES="accounts properties users rooms bookings payments guests invoices audit_logs"
    LIVE=(kubectl --context "$CTX" -n "$NS" exec stayledger-postgres-0 -c postgres -- sh -c) LIVE_DB=$PMS_DB ;;
  ai)
    NS=stayledger-ai-assistant; LABEL=postgres-backup-offnode; PREFIX="stayledger-ai-assistant/${ENV}/postgres/"; PATTERN="hotel_ops_"
    TABLES="tenant_runtime_config conversations kb_generations kb_chunks usage_events bookings audit_logs"
    PGDEP=$([ "$ENV" = staging ] && echo stayledger-ai-assistant-postgres || echo postgres)
    LIVE=(kubectl --context "$CTX" -n "$NS" exec "deploy/$PGDEP" -- sh -c) LIVE_DB='${POSTGRES_DB:-hotel_ops}' ;;
  *) echo "bad db"; exit 2 ;;
esac

NAME="restore-drill-${DB}-$(date +%m%d%H%M)"
sed -e "s#__NAME__#${NAME}#" -e "s#__NAMESPACE__#${NS}#" -e "s#__LABEL_NAME__#${LABEL}#g" \
    -e "s#__SECRET__#backup-offnode-s3#" -e "s#__PREFIX__#${PREFIX}#" -e "s#__PATTERN__#${PATTERN}#" \
    -e "s#__TABLES__#${TABLES}#" \
    "$ROOT/stayledger-shared/datastores/restore-drill/restore-drill-job.template.yaml" \
  | kubectl --context "$CTX" apply -f - >/dev/null
echo "== $ENV/$DB: job $NAME in $NS"
START=$(date +%s)
if ! kubectl --context "$CTX" -n "$NS" wait --for=condition=complete "job/$NAME" --timeout=3600s >/dev/null 2>&1; then
  kubectl --context "$CTX" -n "$NS" logs "job/$NAME" --all-containers --tail=40 || true
  echo "DRILL FAILED"; exit 1
fi
echo "wall_clock_s=$(( $(date +%s) - START ))"
kubectl --context "$CTX" -n "$NS" logs "job/$NAME" --all-containers | grep "^\[drill\]"
echo "-- live (read-only) --"
for t in $TABLES; do
  echo "live rows ${t}=$("${LIVE[@]}" "psql -U \${POSTGRES_USER:-postgres} -d ${LIVE_DB} -Atc 'select count(*) from ${t}'" 2>/dev/null | tail -1)"
done
kubectl --context "$CTX" -n "$NS" delete job "$NAME" --wait=false >/dev/null
