#!/usr/bin/env bash
# Remaining go-live steps after the 2026-09-27 production round
# (stayledger-ai-assistant-api docs/reviews/golive-review-20260927.md).
#
# Run from the stayledger-infra root:   bash scripts/finish-golive-20260928.sh [step...]
# Steps (default: all, in this order):
#   ai-backup-staging     Secret backup-offnode-s3 in the AI namespace + one verified off-node upload
#   ai-backup-production  same on production (applies the CronJob/ConfigMap/NetworkPolicy first)
#   alerts                production Alertmanager: SMTP Secret, matcher strategy, config, test alert
#   headers               AI admin-web fd4ed63 (security headers) on production
#   pms-key-staging       regenerate the truncated staging PMS web-chat RS256 key
#
# Every Secret value travels through a pipe only; nothing secret is printed.
# Stops at the first failure.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash rewrites /app/... style arguments otherwise
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
step() { printf '\n=== %s\n' "$*"; }

run_offnode_test() {  # $1 context
  local k="kubectl --context $1 -n stayledger-ai-assistant" job
  job="ai-offnode-verify-$(date +%H%M%S)"
  $k create job "$job" --from=cronjob/postgres-backup-offnode
  $k wait --for=condition=complete "job/$job" --timeout=900s || { $k logs "job/$job" --tail=30; return 1; }
  $k logs "job/$job" | tail -4
}

ai_backup_staging() {
  step "AI DB off-node backup — staging"
  bash stayledger-ai-assistant-api/copy-backup-offnode-secret.sh staging
  run_offnode_test HK-HUB-Cluster
}

ai_backup_production() {
  step "AI DB off-node backup — production"
  bash stayledger-ai-assistant-api/copy-backup-offnode-secret.sh production
  # The production overlay cannot be `apply -k`'d (postgres PV path), so apply the objects
  # directly with the production prefix.
  sed 's#stayledger-ai-assistant/CHANGE-ME/postgres/#stayledger-ai-assistant/production/postgres/#' \
    stayledger-ai-assistant-api/base/datastores/postgres-backup-offnode-cronjob.yaml \
    | kubectl --context stayledger apply -f -
  kubectl --context stayledger apply -f \
    stayledger-ai-assistant-api/base/security/network-policies/allow-postgres-backup-offnode-egress.yaml
  run_offnode_test stayledger
}

alerts() {
  step "Production Alertmanager"
  if ! kubectl --context stayledger -n observability get secret alertmanager-smtp >/dev/null 2>&1; then
    kubectl --context stayledger -n stayledger get secret stayledger-secrets -o json \
      | python -c "import json,sys; d=json.load(sys.stdin)['data']; print(json.dumps({'apiVersion':'v1','kind':'Secret','metadata':{'name':'alertmanager-smtp','namespace':'observability'},'type':'Opaque','data':{'smtp-password':d['smtp-password']}}))" \
      | kubectl --context stayledger apply -f -
  fi
  bash stayledger-shared/production/apply-alertmanager-config.sh
  sleep 45
  kubectl --context stayledger -n observability exec alertmanager-kps-alertmanager-0 -c alertmanager -- \
    amtool alert add GoLiveAlertTest severity=critical env=production \
      --annotation=summary="Go-live test alert: production Alertmanager can email platform@stayledger.io" \
      --end="$(date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ)" \
      --alertmanager.url=http://localhost:9093
  echo "A CRITICAL GoLiveAlertTest email should reach platform@stayledger.io within ~1 minute."
}

headers() {
  step "AI admin-web security headers — production"
  local k="kubectl --context stayledger -n stayledger-ai-assistant"
  $k set image deploy/stayledger-ai-assistant-admin-web \
    "frontend=putin111/stayledger-ai-assistant-admin-web@sha256:4e460cc96736383d601f0e443ed4f8cfaddc00a59deffebadf4d9a8ff354b19f"
  $k rollout status deploy/stayledger-ai-assistant-admin-web --timeout=420s
  echo "security headers: $(curl -sI https://assistant.stayledger.io/admin/login | grep -ciE 'strict-transport|x-frame|x-content-type|referrer|permissions|content-security') (expect 6)"
  echo "login with bad credentials: $(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' \
    -d '{"email":"nobody@example.com","password":"wrong-password"}' https://assistant.stayledger.io/api/admin/auth/login) (expect 401)"
}

pms_key_staging() {
  step "Staging PMS web-chat key"
  bash stayledger-api/staging/rotate-pms-web-chat-jwt.sh
}

STEPS=("$@")
[ ${#STEPS[@]} -eq 0 ] && STEPS=(ai-backup-staging ai-backup-production alerts headers pms-key-staging)
for s in "${STEPS[@]}"; do
  case "$s" in
    ai-backup-staging) ai_backup_staging ;;
    ai-backup-production) ai_backup_production ;;
    alerts) alerts ;;
    headers) headers ;;
    pms-key-staging) pms_key_staging ;;
    *) echo "unknown step: $s"; exit 2 ;;
  esac
done
step "done — then: commit stayledger-infra (prod admin-web digest fd4ed63, staging PMS KID) and rerun the staging e2e smoke"
