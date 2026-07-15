# ArgoCD — StayLedger Staging

GitOps continuous deployment for the `stayledger-staging` namespace on `hkk8s-hub-master`.

| Key | Value |
| --- | --- |
| ArgoCD version | **v3.4.3** |
| Cluster node | `hkk8s-hub-master` (`10.89.1.40`) |
| ArgoCD UI | `http://10.89.1.40:30082` |
| Target namespace | `stayledger-staging` |
| Tracked branch | `staging` |

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Install ArgoCD](#2-install-argocd)
3. [Install ArgoCD CLI](#3-install-argocd-cli)
4. [First Login & Change Password](#4-first-login--change-password)
5. [Add Private Repo Credentials](#5-add-private-repo-credentials)
6. [Deploy Staging Applications](#6-deploy-staging-applications)
7. [Application Overview](#7-application-overview)
8. [Day-2 Operations](#8-day-2-operations)
9. [Uninstall ArgoCD](#9-uninstall-argocd)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Prerequisites

- `kubectl` configured and pointing at the target cluster:

  ```bash
  kubectl get nodes
  # NAME                STATUS   ROLES           AGE
  # hkk8s-hub-master    Ready    control-plane   ...
  ```

- `curl` available on the machine running the install script.
- The `stayledger-staging` Kubernetes secrets must already exist (see
  `stayledger-shared/k8s/staging/generate-secrets.ps1`).

---

## 2. Install ArgoCD

### Windows (PowerShell) — recommended

Run the PowerShell install script from the root of this repo:

```powershell
.\argocd\install\install.ps1
```

### Linux / WSL

```bash
chmod +x argocd/install/install.sh
./argocd/install/install.sh
```

### What the scripts do

| Step | Action |
| --- | --- |
| 1 | Creates the `argocd` namespace (idempotent). |
| 2 | Applies the official ArgoCD v3.4.3 manifest. |
| 3 | Applies the `applicationsets` CRD via server-side apply (avoids annotation size limit). |
| 4 | Applies `argocd-params.yaml` — enables insecure (plain HTTP) mode. |
| 5 | Waits up to 5 minutes for all deployments to roll out. |
| 6 | Applies `argocd-nodeport.yaml` — exposes the UI on NodePort **30082**. |
| 7 | Restarts the server so it picks up the insecure-mode config. |

### Manual install (step-by-step)

```bash
# 1. Namespace
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# 2. Core manifests
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.3/manifests/install.yaml

# 3. Fix large CRD annotation (server-side apply)
kubectl apply --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.3/manifests/crds/applicationset-crd.yaml

# 4. Insecure mode
kubectl apply -f argocd/install/argocd-params.yaml

# 5. Wait for rollout
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s

# 6. NodePort service
kubectl apply -f argocd/install/argocd-nodeport.yaml

# 7. Restart to pick up config
kubectl rollout restart deployment/argocd-server -n argocd
kubectl rollout status deployment/argocd-server -n argocd --timeout=120s
```

### Verify the installation

```bash
kubectl get pods -n argocd
```

Expected output (all pods `Running`):

```text
NAME                                               READY   STATUS
argocd-application-controller-0                    1/1     Running
argocd-applicationset-controller-...               1/1     Running
argocd-dex-server-...                              1/1     Running
argocd-notifications-controller-...                1/1     Running
argocd-redis-...                                   1/1     Running
argocd-repo-server-...                             1/1     Running
argocd-server-...                                  1/1     Running
```

---

## 3. Install ArgoCD CLI

The CLI is optional but useful for syncing and checking status from the terminal.

**Windows (PowerShell):**

```powershell
$version = "v3.4.3"
Invoke-WebRequest `
  -Uri "https://github.com/argoproj/argo-cd/releases/download/$version/argocd-windows-amd64.exe" `
  -OutFile "$env:LOCALAPPDATA\Microsoft\WindowsApps\argocd.exe"
argocd version --client
```

**Linux / WSL:**

```bash
curl -sSL -o /tmp/argocd \
  https://github.com/argoproj/argo-cd/releases/download/v3.4.3/argocd-linux-amd64
chmod +x /tmp/argocd
sudo mv /tmp/argocd /usr/local/bin/argocd
argocd version --client
```

**macOS:**

```bash
brew install argocd
```

---

## 4. First Login & Change Password

### Get the initial admin password

**Windows (PowerShell):**

```powershell
$encoded = kubectl -n argocd get secret argocd-initial-admin-secret `
  -o jsonpath="{.data.password}"
[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded))
```

**Linux / WSL / macOS:**

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

### Login via CLI

```bash
argocd login 10.89.1.40:30082 \
  --username admin \
  --password <initial-password> \
  --insecure
```

### Change the admin password

```bash
argocd account update-password \
  --current-password <initial-password> \
  --new-password <your-new-password>
```

### Login via browser

Open `http://10.89.1.40:30082` and sign in with `admin` / `<initial-password>`.

> **Security note:** Delete the initial admin secret after changing the password:
>
> ```bash
> kubectl -n argocd delete secret argocd-initial-admin-secret
> ```

---

## 5. Add Private Repo Credentials

The GitHub repositories under `tuantruong379` are private. ArgoCD needs a
Personal Access Token (PAT) to clone them.

### Create a GitHub PAT

1. Go to **GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens**
2. Grant **Contents: Read-only** on repositories:
   - `tuantruong379/stayledger-shared`
   - `tuantruong379/stayledger-api`
   - `tuantruong379/stayledger-admin-web`

### Register each repo in ArgoCD

```bash
# Replace <YOUR_GITHUB_PAT> with the token you created above.
PAT="<YOUR_GITHUB_PAT>"
GITHUB_USER="tuantruong379"

for repo in stayledger-shared stayledger-api stayledger-admin-web; do
  argocd repo add "https://github.com/${GITHUB_USER}/${repo}.git" \
    --username "${GITHUB_USER}" \
    --password "${PAT}" \
    --insecure-skip-server-verification
done
```

### Verify repos are connected

```bash
argocd repo list
```

All three repos should show `Successful` in the `CONNECTION STATUS` column.

---

## 6. Deploy Staging Applications

Apply the three ArgoCD Application manifests **in order** (infrastructure must be
`Healthy` before the API is applied, and the API `Healthy` before admin-web).

```bash
# 1. Shared infrastructure (namespace, postgres, redis, storage)
kubectl apply -f argocd/staging/app-infrastructure.yaml
argocd app wait stayledger-staging-infrastructure --health --timeout 300

# 2. API (migration PreSync hook runs automatically before the Deployment rolls out)
kubectl apply -f argocd/staging/app-api.yaml
argocd app wait stayledger-staging-api --health --timeout 300

# 3. Admin web
kubectl apply -f argocd/staging/app-admin-web.yaml
argocd app wait stayledger-staging-admin-web --health --timeout 300
```

### Verify in the UI

Open `http://10.89.1.40:30082` — all three Applications should be green
(`Synced` + `Healthy`).

---

## 7. Application Overview

| Application | Repo | Path | Manages |
| --- | --- | --- | --- |
| `stayledger-staging-infrastructure` | `stayledger-shared` @ `staging` | `k8s/staging` | Namespace, StorageClass, PVs, PostgreSQL, Redis |
| `stayledger-staging-api` | `stayledger-api` @ `staging` | `k8s/staging` | ConfigMap, Deployment, Services; migration runs as PreSync hook |
| `stayledger-staging-admin-web` | `stayledger-admin-web` @ `staging` | `k8s/staging` | ConfigMap, Deployment, NodePort Service |

All three Applications have **automated sync** enabled with `prune: true` and
`selfHeal: true` — any commit to the `staging` branch is applied to the cluster
within ~3 minutes.

---

## 8. Day-2 Operations

### Deploy a new image tag

Update the image tag in the relevant `k8s/staging/deployment.yaml` (and
`k8s/staging/migration-job.yaml` for the API), commit to `staging`, and push.
ArgoCD detects the change and syncs automatically.

```bash
NEW_TAG="abc1234"   # 7-char short commit from GitHub Actions summary (no sha- prefix)

# In stayledger-api repo:
sed -i "s|putin111/stayledger-api:.*|putin111/stayledger-api:${NEW_TAG}|g" \
  k8s/staging/deployment.yaml \
  k8s/staging/migration-job.yaml

git add k8s/staging/deployment.yaml k8s/staging/migration-job.yaml
git commit -m "deploy: ${NEW_TAG}"
git push origin staging
```

ArgoCD will:

1. Detect the git change (~3 min polling or webhook).
2. Run the `migration-job.yaml` PreSync hook (Prisma `migrate deploy`).
3. Roll out the new Deployment once the migration succeeds.

### Force a manual sync

```bash
argocd app sync stayledger-staging-api
```

### Check sync status

```bash
argocd app list
argocd app get stayledger-staging-api
```

### Roll back to a previous revision

```bash
# List history
argocd app history stayledger-staging-api

# Roll back to revision N
argocd app rollback stayledger-staging-api <N>
```

### View migration job logs

```bash
kubectl logs -n stayledger-staging \
  -l app=stayledger-api,component=migration \
  --tail=100
```

### Disable auto-sync temporarily (e.g. during maintenance)

```bash
argocd app set stayledger-staging-api --sync-policy none
# re-enable:
argocd app set stayledger-staging-api --sync-policy automated
```

---

## 9. Uninstall ArgoCD

```bash
# Remove Applications first (triggers resource pruning in the cluster)
kubectl delete -f argocd/staging/app-admin-web.yaml
kubectl delete -f argocd/staging/app-api.yaml
kubectl delete -f argocd/staging/app-infrastructure.yaml

# Then remove ArgoCD itself
kubectl delete -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.3/manifests/install.yaml

kubectl delete namespace argocd
```

---

## 10. Troubleshooting

### ArgoCD server pod is in `CrashLoopBackOff`

```bash
kubectl logs -n argocd deployment/argocd-server --previous
```

Common cause: the `argocd-cmd-params-cm` ConfigMap was applied before the
Deployment finished its first rollout. Fix: restart the server.

```bash
kubectl rollout restart deployment/argocd-server -n argocd
```

### Application stuck in `OutOfSync` after migration job

The migration Job is a PreSync hook with `BeforeHookCreation,HookSucceeded`
delete policy. If the job fails, it is kept for inspection.

```bash
# Check why the migration failed
kubectl describe job stayledger-db-migrate -n stayledger-staging
kubectl logs -n stayledger-staging job/stayledger-db-migrate

# Once fixed, delete the failed job and retry sync
kubectl delete job stayledger-db-migrate -n stayledger-staging
argocd app sync stayledger-staging-api
```

### `ComparisonError: failed to load target state` — repo not accessible

ArgoCD cannot clone the repository. Verify credentials:

```bash
argocd repo list
argocd repo get https://github.com/tuantruong379/stayledger-api.git
```

Re-add the repository with a fresh PAT if the token has expired.

### NodePort 30082 unreachable

```bash
# Check the service was applied correctly
kubectl get svc argocd-server -n argocd

# Check the server pod is running
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server

# Check firewall rules on the node allow port 30082 (run on hkk8s-hub-master)
sudo iptables -L INPUT -n | grep 30082
```

### Reset admin password (if lost)

```bash
NEW_HASH=$(argocd account bcrypt --password <new-password>)

kubectl -n argocd patch secret argocd-secret \
  -p "{\"stringData\": {\"admin.password\": \"${NEW_HASH}\", \"admin.passwordMtime\": \"$(date +%FT%T%Z)\"}}"

kubectl rollout restart deployment/argocd-server -n argocd
```
