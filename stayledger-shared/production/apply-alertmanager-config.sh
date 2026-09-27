#!/usr/bin/env bash
# Apply the production AlertmanagerConfig (see alertmanager-config.yaml next to this file).
# Prerequisite, once: Secret observability/alertmanager-smtp with key smtp-password, e.g.
#   kubectl --context stayledger -n stayledger get secret stayledger-secrets -o json \
#     | python -c "import json,sys; d=json.load(sys.stdin)['data']; print(json.dumps({'apiVersion':'v1','kind':'Secret','metadata':{'name':'alertmanager-smtp','namespace':'observability'},'type':'Opaque','data':{'smtp-password':d['smtp-password']}}))" \
#     | kubectl --context stayledger apply -f -
set -euo pipefail
CTX=stayledger
DIR=$(cd "$(dirname "$0")" && pwd)
kubectl --context "$CTX" -n observability get secret alertmanager-smtp >/dev/null
# Without this the operator adds namespace="observability" to every route (OnNamespace).
# Also set in kube-prometheus-stack-values-production.yaml so a helm upgrade keeps it.
kubectl --context "$CTX" -n observability patch alertmanager kps-alertmanager --type merge \
  -p '{"spec":{"alertmanagerConfigMatcherStrategy":{"type":"None"}}}'
USER_B64=$(kubectl --context "$CTX" -n stayledger get secret stayledger-secrets -o jsonpath='{.data.smtp-user}')
SES_USER=$(printf '%s' "$USER_B64" | base64 -d)
sed "s|__SES_SMTP_USERNAME__|${SES_USER}|g" "$DIR/alertmanager-config.yaml" | kubectl --context "$CTX" apply -f -
echo "applied; receivers now:"
kubectl --context "$CTX" get --raw "/api/v1/namespaces/observability/services/kps-alertmanager:9093/proxy/api/v2/status" \
  | python -c "import json,sys,re; print(re.findall(r'- name: ?\"?([^\"\n]+)', json.load(sys.stdin)['config']['original']))"
