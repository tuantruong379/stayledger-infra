# Owner-DSN Alembic migration runbook (staging)

## Why

Alembic `ALTER TABLE` failed under the app DSN (`must be owner of table …`).
Schema ownership remains with table owner `hotelassistant`. The application
role `stayledger_ai_app` must never gain DDL.

## Procedure

1. Confirm context: `kubectl config current-context` → `HK-HUB-Cluster`.
2. Ensure Secret `stayledger-ai-assistant-migration-secrets` exists with key
   `HOTEL_OPS_DSN_OWNER` (owner DSN only; never copy into app secret).
3. Copy `alembic-upgrade-owner-TEMPLATE.yaml` → unique UTC name.
4. Pin Job image to the candidate API digest.
5. Apply Job; wait for Complete.
6. Verify: `SELECT version_num FROM alembic_version;` matches expected head.
7. Only then roll the API Deployment via Kustomize digest pin (no `kubectl set image`).

## Fail closed

- If `HOTEL_OPS_DSN_OWNER` is unset, the Job exits 2.
- Do not stamp `alembic_version` without applying DDL.
- Do not grant app role table ownership to “make Job work”.
