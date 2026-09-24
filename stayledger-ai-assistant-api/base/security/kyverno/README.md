# Kyverno policies — deliberately not wired in

These 4 `ClusterPolicy` manifests (non-root, read-only rootfs, resource limits, no
`:latest` tags) are written and ready, but not referenced by any `kustomization.yaml`
on either environment, and Kyverno itself is not installed on either cluster
(`HK-HUB-Cluster` staging or `stayledger` production).

This is deferred security hardening, not abandoned work: installing a policy engine
and enforcing these cluster-wide is bigger scope than any single hygiene/cleanup pass
should take on unilaterally (Kyverno's admission webhook can block legitimate
deploys if a policy is miscalibrated, so it needs its own rollout plan — install in
`background: true`/audit mode first, verify no false positives against real traffic,
then flip to `Enforce`).

Confirmed 2026-09-23: still true — zero kustomization references, Kyverno not
installed on either cluster. Revisit as a dedicated piece of work, not folded into
routine cleanup.
