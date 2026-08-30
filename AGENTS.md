# AGENTS.md

## Repository Purpose

Kubernetes / GitOps manifests for StayLedger (`stayledger-infra`). Follow workspace rules in `D:\Repositories\.cursorrules` and `D:\Repositories\.cursor\rules\`. Staging context: `HK-HUB-Cluster`. Production context: `stayledger`.

## Release branching (workspace policy)

Canonical: `docs/guides/stayledger-release-branching.md` (workspace root). Cursor rule: `.cursor/rules/stayledger-release-branching.mdc`.

- Ship product/deployable work -> new `release/MAJOR.MINOR.PATCH` (do not keep committing on the previous release branch).
- Bump: `PATCH++`; if `PATCH > 9` -> `PATCH = 0`, `MINOR++`; if `MINOR > 9` -> `MINOR = 0`, `MAJOR++` (main++). Digits are 0-9.
- Examples: `1.1.2` -> `1.1.3`; `1.1.9` -> `1.2.0`; `1.9.9` -> `2.0.0`.
- **No bump** when the change is only `Jenkinsfile` / Jenkins pipeline and/or build-pipeline security hardening - commit/push on the current branch. Mixed app + pipeline changes still bump.
