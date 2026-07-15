# TLS edge for stayledger production cluster (context: stayledger / k3s + Traefik)
#
# 1. Install cert-manager v1.21.0
#    kubectl --context stayledger apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.0/cert-manager.yaml
#
# 2. Apply ClusterIssuers
#    kubectl --context stayledger apply -f stayledger-shared/production/tls-edge/cert-manager-issuer.yaml
#
# 3. Wire Ingress TLS (landing example)
#    kubectl --context stayledger apply -f stayledger-landing/prd/ingress.yaml
#
# 4. Wait for certificate
#    kubectl --context stayledger -n stayledger get certificate,order,challenge -A
#    kubectl --context stayledger -n stayledger describe certificate stayledger-landing-tls
#
# Cloudflare (orange cloud) + HTTP-01:
# - SSL/TLS mode: Full or Full (strict) after a real cert is Ready
# - "Always Use HTTPS" can break ACME HTTP-01 — leave off until Ready, or use DNS-01
