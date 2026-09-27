#!/usr/bin/env bash
# Copy the PMS off-node S3 credentials into the AI-assistant namespace as Secret backup-offnode-s3
# (used by postgres-backup-offnode). S3_PREFIX is dropped: the CronJob sets its own per env.
# Values go through the pipe only; nothing is printed.
#   bash copy-backup-offnode-secret.sh staging      # HK-HUB-Cluster: stayledger-staging -> stayledger-ai-assistant
#   bash copy-backup-offnode-secret.sh production   # stayledger:     stayledger         -> stayledger-ai-assistant
set -euo pipefail
case "${1:-}" in
  staging)    CTX=HK-HUB-Cluster; SRC_NS=stayledger-staging ;;
  production) CTX=stayledger;     SRC_NS=stayledger ;;
  *) echo "usage: $0 staging|production"; exit 2 ;;
esac
kubectl --context "$CTX" -n "$SRC_NS" get secret backup-offnode-s3 -o json \
  | python -c "
import json, sys
d = json.load(sys.stdin)['data']
keep = {k: v for k, v in d.items() if k in ('S3_ENDPOINT', 'S3_ACCESS_KEY_ID', 'S3_SECRET_ACCESS_KEY', 'S3_BUCKET')}
missing = {'S3_ENDPOINT', 'S3_ACCESS_KEY_ID', 'S3_SECRET_ACCESS_KEY', 'S3_BUCKET'} - keep.keys()
if missing: sys.exit(f'source secret lacks {sorted(missing)}')
print(json.dumps({'apiVersion': 'v1', 'kind': 'Secret', 'type': 'Opaque',
                  'metadata': {'name': 'backup-offnode-s3', 'namespace': 'stayledger-ai-assistant',
                               'labels': {'app.kubernetes.io/part-of': 'stayledger-ai-assistant'}},
                  'data': keep}))" \
  | kubectl --context "$CTX" apply -f -
echo "done; test with:"
echo "  kubectl --context $CTX -n stayledger-ai-assistant create job ai-offnode-test-\$(date +%H%M) --from=cronjob/postgres-backup-offnode"
