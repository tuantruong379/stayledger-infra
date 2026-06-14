#!/usr/bin/env bash
# install.sh — Install ArgoCD v3.4.3 on hkk8s-hub-master (single-node staging).
#
# Prerequisites:
#   - kubectl configured and pointing at the target cluster
#   - curl available
#
# Usage:
#   chmod +x argocd/install/install.sh
#   ./argocd/install/install.sh
set -euo pipefail

ARGOCD_VERSION="v3.4.3"
ARGOCD_NAMESPACE="argocd"
INSTALL_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> [1/6] Creating namespace ${ARGOCD_NAMESPACE}"
kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "==> [2/7] Applying ArgoCD ${ARGOCD_VERSION} install manifest"
kubectl apply -n "${ARGOCD_NAMESPACE}" -f "${INSTALL_MANIFEST}"

# The applicationsets CRD has annotations that exceed the 262 kB client-side limit.
echo "==> [3/7] Applying applicationsets CRD via server-side apply"
kubectl apply --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/crds/applicationset-crd.yaml"

echo "==> [4/7] Applying insecure-mode config (HTTP only, no TLS)"
kubectl apply -f "${SCRIPT_DIR}/argocd-params.yaml"

echo "==> [5/7] Waiting for ArgoCD server to be ready (up to 5 min)"
kubectl rollout status deployment/argocd-server -n "${ARGOCD_NAMESPACE}" --timeout=300s

echo "==> [6/7] Exposing ArgoCD server via NodePort"
kubectl apply -f "${SCRIPT_DIR}/argocd-nodeport.yaml"

# Restart the server so it picks up the insecure-mode config
echo "==> [7/7] Restarting argocd-server to pick up insecure-mode config"
kubectl rollout restart deployment/argocd-server -n "${ARGOCD_NAMESPACE}"
kubectl rollout status deployment/argocd-server -n "${ARGOCD_NAMESPACE}" --timeout=120s

echo ""
echo "==> Installation complete"
echo ""
echo "  UI:              http://10.89.1.40:30080"
echo "  Username:        admin"
INITIAL_PASSWORD=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "(secret not found — already initialised)")
echo "  Initial password: ${INITIAL_PASSWORD}"
echo ""
echo "  Next steps:"
echo "    1. Log in and change the password (see README.md)."
echo "    2. Add GitHub credentials (see README.md — 'Add private repo credentials')."
echo "    3. Apply the staging Applications:"
echo "         kubectl apply -f argocd/staging/app-infrastructure.yaml"
echo "         kubectl apply -f argocd/staging/app-api.yaml"
echo "         kubectl apply -f argocd/staging/app-admin-web.yaml"
