# TLS edge manifests (temporarily disabled)

The Ingress + cert-manager ClusterIssuer live here instead of `k8s/onprem/` root so they are **not** part of the default deployment surface while TLS at the edge is deferred.

**Re-enable:** copy both YAML files back to `k8s/onprem/`:

```bash
cp k8s/onprem/disabled/tls-edge/ingress.yaml k8s/onprem/ingress.yaml
cp k8s/onprem/disabled/tls-edge/cert-manager-issuer.yaml k8s/onprem/cert-manager-issuer.yaml
```

Then restore the TLS assertion in `tests/test_release_manifest_constraints.py::test_tls_edge_manifests_are_present_for_second_step_apply` (remove `@pytest.mark.skip`).

Apply order (unchanged):

```bash
kubectl apply -f k8s/onprem/cert-manager-issuer.yaml
kubectl apply -f k8s/onprem/ingress.yaml
```
