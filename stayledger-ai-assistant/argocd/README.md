# ArgoCD GitOps Setup

Thư mục này chứa các manifest ArgoCD để thiết lập vòng lặp GitOps tự động cho **AI Hotel Assistant** trên môi trường on-premises.

---

## Cấu trúc file

```
k8s/argocd/
├── kustomization.yaml              # Entry point — danh sách tài nguyên cần apply
├── project.yaml                    # AppProject — phân quyền và giới hạn bảo mật
└── hotel-assistant-application.yaml # Application — vòng lặp GitOps chính
```

---

## 1. kustomization.yaml — Entry point

```yaml
resources:
  - project.yaml
  - hotel-assistant-application.yaml
```

Chỉ là danh sách tài nguyên để Kustomize biết cần apply những gì. Khi chạy lệnh sau, nó sẽ lần lượt tạo `project.yaml` và `hotel-assistant-application.yaml` vào cluster:

```bash
kubectl apply -k k8s/argocd/
```

---

## 2. project.yaml — AppProject: Phân quyền và giới hạn

`AppProject` là vùng cô lập bảo mật trong ArgoCD — giống như một "tenant" riêng. Nó kiểm soát những gì Application bên trong được phép làm.

| Thuộc tính | Giá trị | Ý nghĩa |
|---|---|---|
| `sourceRepos` | GitHub repo của project | Chỉ cho phép kéo manifest từ repo này, không repo nào khác |
| `destinations` | namespace `hotel-assistant` | Chỉ deploy được vào namespace này trên cluster nội bộ |
| `clusterResourceWhitelist` | `Namespace`, `StorageClass` | Cho phép tạo cluster-level resource |
| `namespaceResourceWhitelist` | `group: "*", kind: "*"` | Bên trong namespace, cho phép tạo mọi loại resource |

**Tại sao cần AppProject?** Ngăn các Application vô tình hoặc cố ý deploy sang namespace khác hoặc kéo manifest từ repo không tin cậy.

### Ý nghĩa của resource whitelist

ArgoCD tách quyền apply resource thành 2 nhóm:

| Nhóm | Trong file này cho phép | Ý nghĩa vận hành |
|---|---|---|
| `clusterResourceWhitelist` | `Namespace`, `StorageClass` | Đây là các resource cấp cluster, không thuộc riêng một namespace. `Namespace` cần cho `CreateNamespace=true`; `StorageClass` cần cho các manifest storage on-prem như Postgres/Redis PV/PVC. Không whitelist rộng để tránh Application tự tạo các quyền nhạy cảm cấp cluster như `ClusterRole`, `ClusterRoleBinding`, CRD, webhook admission... |
| `namespaceResourceWhitelist` | `group: "*", kind: "*"` | Trong phạm vi namespace đích `hotel-assistant`, Application được tạo mọi loại resource: `Deployment`, `Service`, `ConfigMap`, `Secret` template, `NetworkPolicy`, `HPA`, `PDB`, `ServiceAccount`, v.v. Phạm vi vẫn bị chặn bởi `destinations`, nên không được deploy sang namespace khác. |

Nói ngắn gọn: cluster-level thì mở rất ít, namespace-level thì mở rộng để app vận hành đầy đủ trong namespace riêng.

---

## 3. hotel-assistant-application.yaml — Application: Vòng lặp GitOps

Đây là file quan trọng nhất — định nghĩa vòng lặp GitOps chính.

### Source (nguồn manifest)

```yaml
source:
  repoURL: https://github.com/tuantruong379/ai-hotel-assistant.git
  targetRevision: release/3.1.1
  path: k8s/onprem
```

ArgoCD đọc tất cả manifest trong thư mục `k8s/onprem/` từ branch `release/3.1.1`.

### Destination (nơi deploy)

```yaml
destination:
  server: https://kubernetes.default.svc
  namespace: hotel-assistant
```

Deploy vào cluster nội bộ (on-prem), namespace `hotel-assistant`.

### Sync Policy (tự động hóa)

```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - CreateNamespace=true
    - PruneLast=true
    - ApplyOutOfSyncOnly=true
```

| Option | Ý nghĩa |
|---|---|
| `prune: true` | Xóa resource trong cluster nếu bị xóa khỏi Git |
| `selfHeal: true` | Tự restore nếu ai đó sửa trực tiếp trên cluster ngoài Git |
| `CreateNamespace=true` | Tự tạo namespace nếu chưa tồn tại |
| `PruneLast=true` | Xóa resource cũ **sau khi** tạo resource mới (tránh downtime) |
| `ApplyOutOfSyncOnly=true` | Chỉ apply những resource thực sự khác với trạng thái trong Git |

### Argo CD Image Updater

Phần `annotations` cấu hình **Argo CD Image Updater** — controller bổ sung giúp tự động cập nhật image tag khi có build mới.

Lưu ý quan trọng: **Image Updater không nằm sẵn trong ArgoCD mặc định**. ArgoCD core chỉ theo dõi Git và sync manifest. Muốn ArgoCD tự phát hiện image mới trên Docker Hub rồi ghi tag mới vào Git thì phải cài thêm `argocd-image-updater` như một controller riêng trong cluster, thường trong namespace `argocd`. Nếu controller này chưa được cài, các annotation bên dưới chỉ là metadata và không tự làm gì.

Argo CD Image Updater là dự án riêng dưới `argoproj-labs/argocd-image-updater`. Release đầu tiên `v0.1.0` được publish ngày `2020-08-05` với mô tả "Initial release of ArgoCD Image Updater". Các tài liệu hiện tại mô tả cách chạy chuẩn là một controller riêng trong cluster; không phải một tính năng built-in của ArgoCD core.

Manifest hiện tại dùng cấu hình annotation-style:

```yaml
annotations:
  argocd-image-updater.argoproj.io/image-list: api=putin111/ai-hotel-assistant,frontend=putin111/ai-hotel-assistant-frontend
  argocd-image-updater.argoproj.io/write-back-method: git
  argocd-image-updater.argoproj.io/git-branch: release/3.1.1
  argocd-image-updater.argoproj.io/api.allow-tags: regexp:^sha-[0-9a-f]{7,40}$
  argocd-image-updater.argoproj.io/api.update-strategy: newest-build
```

| Annotation | Ý nghĩa |
|---|---|
| `image-list` | Theo dõi 2 image: `api` và `frontend` trên Docker Hub |
| `allow-tags` | Chỉ chấp nhận tag dạng `sha-abc1234` (tạo bởi GitHub Actions CD workflow) |
| `update-strategy: newest-build` | Khi phát hiện image mới nhất, tự động cập nhật |
| `write-back-method: git` | Ghi image tag mới ngược lại vào Git repo thay vì chỉ patch trực tiếp cluster |

Với các bản Image Updater mới, cấu hình chính thức đã chuyển dần sang CRD `ImageUpdater`. Kiểu annotation vẫn cần được kiểm tra theo version Image Updater thực tế trước khi rollout production.

### Registry không phải GitHub/Docker Hub

Image Updater không bắt buộc image phải nằm trên GitHub. Nó đọc tag từ container registry. Theo tài liệu upstream, Image Updater hỗ trợ hầu hết registry triển khai **Docker Registry HTTP API v2**; các registry đã được test gồm Docker Hub, Docker Registry v2 on-prem, Quay, JFrog Artifactory, GHCR, GitLab registry, GCR và ACR. Với ECR hoặc Nexus local, nguyên tắc vẫn là: nếu registry expose Docker Registry v2 API và Image Updater pod truy cập/auth được thì dùng được.

Cần phân biệt 2 loại credential:

| Credential | Dùng bởi | Mục đích |
|---|---|---|
| Image Updater registry credential | `argocd-image-updater` pod | List tag / đọc metadata để chọn tag mới |
| Kubernetes imagePullSecret | workload pods / node runtime | Pull image khi Deployment rollout |

Hai loại này có thể dùng chung một Docker pull secret, nhưng không tự thay thế cho nhau. Image Updater đọc tag thành công chưa chắc workload pull image được nếu namespace `hotel-assistant` thiếu `imagePullSecrets`.

#### Khai báo image từ registry khác

Trong annotation, dùng full image path theo registry:

```yaml
annotations:
  argocd-image-updater.argoproj.io/image-list: api=<registry>/<repo>/ai-hotel-assistant,frontend=<registry>/<repo>/ai-hotel-assistant-frontend
  argocd-image-updater.argoproj.io/write-back-method: git
  argocd-image-updater.argoproj.io/git-branch: release/3.1.1
  argocd-image-updater.argoproj.io/api.allow-tags: regexp:^sha-[0-9a-f]{7,40}$
  argocd-image-updater.argoproj.io/api.update-strategy: newest-build
  argocd-image-updater.argoproj.io/api.kustomize.image-name: putin111/ai-hotel-assistant
```

`api.kustomize.image-name` là image name đang tồn tại trong manifest/kustomization. Còn image trong `image-list` là registry đích mà Image Updater sẽ theo dõi và ghi về Git.

#### Registry credential toàn cục

Nếu registry cần auth, cấu hình `registries.conf` trong `argocd-image-updater-config`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-image-updater-config
  namespace: argocd
data:
  registries.conf: |
    registries:
      - name: Azure ACR
        prefix: myregistry.azurecr.io
        api_url: https://myregistry.azurecr.io
        credentials: pullsecret:argocd/acr-pull-secret

      - name: Nexus Docker Registry
        prefix: nexus.local:5000
        api_url: https://nexus.local:5000
        credentials: pullsecret:argocd/nexus-pull-secret
        limit: 10

      - name: AWS ECR
        prefix: 123456789012.dkr.ecr.ap-southeast-1.amazonaws.com
        api_url: https://123456789012.dkr.ecr.ap-southeast-1.amazonaws.com
        credentials: ext:/app/auth/ecr-login.sh
        credsexpire: 10h
```

Credential formats thường dùng:

| Format | Khi dùng |
|---|---|
| `pullsecret:<namespace>/<secret>` | Dùng Kubernetes Docker pull secret có `.dockerconfigjson` |
| `secret:<namespace>/<secret>#<field>` | Secret field chứa chuỗi `username:password` |
| `env:<ENV_NAME>` | Biến môi trường chứa `username:password` |
| `ext:/absolute/script.sh` | Script sinh credential động, ví dụ ECR/ACR token ngắn hạn |

Với ECR, token thường có hạn, nên dùng `ext:/app/auth/ecr-login.sh` kèm `credsexpire` thay vì hard-code password. Script phải in ra đúng một dòng dạng:

```text
AWS:<ecr-login-password>
```

Ví dụ script:

```sh
#!/bin/sh
set -eu
echo "AWS:$(aws ecr get-login-password --region ap-southeast-1)"
```

Với ACR, có thể dùng Docker pull secret, service principal, hoặc Azure Workload Identity với script `ext:`. Upstream hiện có ví dụ Workload Identity dùng `credentials: ext:/app/auth/auth.sh` và `credsexpire: 1h`.

Với Nexus local, tạo Docker hosted/proxy/group repository, dùng endpoint registry thật như `https://nexus.local:5000`, rồi khai báo `prefix` trùng với prefix image. Nếu Nexus dùng self-signed certificate, nên mount CA vào Image Updater pod; chỉ dùng `insecure: true` cho non-production.

Sau khi sửa `registries.conf`, restart pod `argocd-image-updater` để config registry mới có hiệu lực.

---

## Luồng hoàn chỉnh

### Trước khi có Image Updater

Flow cũ là **ArgoCD chỉ sync khi Git repo có commit mới**:

```
GitHub Actions build & push image mới lên Docker Hub
  → Git manifest/kustomization.yaml không đổi
      → ArgoCD không thấy Git khác biệt
          → Không tự rollout image mới
```

Vì vậy trước đây muốn deploy image mới thì CI hoặc operator phải cập nhật tag trong Git, ví dụ sửa `k8s/onprem/kustomization.yaml`, rồi ArgoCD mới sync.

### Sau khi cài Image Updater

```
GitHub Actions (cd.yml)
  → Build & push Docker image với tag sha-xxxxxxx lên Docker Hub
      → Argo CD Image Updater phát hiện image mới
          → Tự cập nhật image tag trong kustomization.yaml trên Git (write-back)
              → ArgoCD phát hiện Git thay đổi
                  → Auto-sync: apply manifest mới vào cluster
                      → Deployment rolling update hoàn tất
```

Điểm khác biệt là Image Updater đóng vai trò "cầu nối" giữa container registry và Git repo. Nó không deploy trực tiếp theo kiểu bỏ qua GitOps; với `write-back-method: git`, nó tạo commit cập nhật tag trong Git, sau đó ArgoCD sync như bình thường.

---

## Cách apply lên cluster

```bash
# Apply toàn bộ ArgoCD resources (chỉ cần chạy 1 lần khi setup)
kubectl apply -k k8s/argocd/

# Kiểm tra trạng thái Application
kubectl get application -n argocd

# Xem chi tiết sync status
kubectl describe application hotel-assistant-onprem -n argocd
```

Sau khi apply, ArgoCD sẽ tự động theo dõi Git và đồng bộ cluster liên tục — không cần can thiệp thủ công.
