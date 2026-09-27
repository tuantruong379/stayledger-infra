#!/usr/bin/env bash
# Regenerate the staging PMS web-chat RS256 keypair (guest webchat -> AI assistant context JWT).
#
# Why (2026-09-27): PMS_WEB_CHAT_JWT_PRIVATE_KEY in stayledger-staging-secrets held only the
# 27-char "-----BEGIN PRIVATE KEY-----" line since the 2026-08-18 rotation (multi-line value
# truncated), so every guest-chat reply failed in createPrivateKey with
# "DECODER routines::unsupported" and 13 staging smoke tests failed on it. Production keeps the
# feature dormant (no key set) and is unaffected.
#
# Keys are written from files with --from-file semantics via a JSON patch built in memory;
# nothing is printed. The KID changes so the AI assistant's JWKS cache refetches.
set -euo pipefail
CTX=HK-HUB-Cluster
NS=stayledger-staging
KID="pms-web-staging-$(date +%Y%m%d)-regen"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/priv.pem" 2>/dev/null
openssl pkey -in "$TMP/priv.pem" -pubout -out "$TMP/pub.pem"
openssl pkey -in "$TMP/priv.pem" -noout -check >/dev/null   # PKCS8, parses

python - "$TMP/priv.pem" "$TMP/pub.pem" > "$TMP/patch.json" <<'EOF'
import base64, json, sys
enc = lambda p: base64.b64encode(open(p, "rb").read()).decode()
print(json.dumps({"data": {"PMS_WEB_CHAT_JWT_PRIVATE_KEY": enc(sys.argv[1]),
                           "PMS_WEB_CHAT_JWT_PUBLIC_KEY": enc(sys.argv[2])}}))
EOF
kubectl --context "$CTX" -n "$NS" patch secret stayledger-staging-secrets --type merge --patch-file "$TMP/patch.json"
kubectl --context "$CTX" -n "$NS" patch configmap stayledger-api-config --type merge \
  -p "{\"data\":{\"PMS_WEB_CHAT_JWT_KID\":\"$KID\"}}"
kubectl --context "$CTX" -n "$NS" rollout restart deploy/stayledger-api
kubectl --context "$CTX" -n "$NS" rollout status deploy/stayledger-api --timeout=300s
kubectl --context "$CTX" -n "$NS" exec deploy/stayledger-api -- node -e \
  "require('crypto').createPrivateKey(process.env.PMS_WEB_CHAT_JWT_PRIVATE_KEY.replace(/\\\\n/g,'\n')); console.log('private key parses; kid', process.env.PMS_WEB_CHAT_JWT_KID)"
echo "Update stayledger-api/staging/configmap.yaml PMS_WEB_CHAT_JWT_KID to $KID in git."
