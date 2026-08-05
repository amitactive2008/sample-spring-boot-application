# Issue Tracker — v3 Deployment Guide (Kind / Local Kubernetes)

Local Kubernetes deployment of the Issue Tracker using **kind** (Kubernetes IN Docker).
Every service runs as a Kubernetes workload inside a single-node cluster on your laptop.
The manifest layout mirrors production (base layer) through a **Kustomize overlay**
that swaps out AWS-specific resources (RDS, ALB, Secrets Manager) for local equivalents
(in-cluster MySQL, nginx Ingress, plain Kubernetes Secrets).

AI coding agents should follow [`AGENTS.md`](AGENTS.md). See
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for service ownership, dependency direction,
and the base-versus-overlay configuration model.

---

## Table of Contents

0. [Development and AI Contributors](#development-and-ai-contributors)
1. [What Changed from v2](#1-what-changed-from-v2)
2. [Architecture](#2-architecture)
3. [Repository Layout](#3-repository-layout)
4. [Prerequisites](#4-prerequisites)
5. [Quick Deploy — One Command](#5-quick-deploy--one-command)
6. [Step-by-Step Manual Deploy](#6-step-by-step-manual-deploy)
7. [Kustomize Overlay Explained](#7-kustomize-overlay-explained)
8. [Kubernetes Resources Reference](#8-kubernetes-resources-reference)
9. [Verify the Deployment](#9-verify-the-deployment)
10. [Day-2 Operations](#10-day-2-operations)
11. [Tear Down](#11-tear-down)
12. [Security & Code Quality Pipeline](#12-security--code-quality-pipeline)
13. [Automated Pipeline Script](#13-automated-pipeline-script--security-pipelinesh)
    - [13.1 What it covers](#131-what-it-covers)
    - [13.2 Prerequisites](#132-prerequisites)
    - [13.3 Usage](#133-usage)
    - [13.4 Common run scenarios](#134-common-run-scenarios)
    - [13.5 Where it fits in the workflow](#135-where-it-fits-in-the-v3-workflow)
    - [13.6 Reports](#136-reports)
    - [13.7 Terminal output](#137-terminal-output)

---

## Development and AI Contributors

The repository keeps application code, deployment configuration, and generated artifacts
separate:

| Path | Purpose |
|---|---|
| `api-gateway/` | JWT validation and public request routing |
| `auth-service/` | Authentication and user administration |
| `issue-service/` | Issue workflow and history |
| `frontend-service/` | React browser application |
| `kubernetes/base/` | Environment-neutral Kubernetes resources |
| `kubernetes/environments/kind/` | Local cluster overlay and infrastructure |
| `scripts/` | Repeatable verification and deployment commands |

Run the smallest relevant verification group before committing:

```bash
./scripts/verify.sh backend
./scripts/verify.sh frontend
./scripts/verify.sh manifests
./scripts/verify.sh shell
./scripts/verify.sh all
```

Backend tests use isolated in-memory H2 databases and test-only credentials. Frontend
verification writes its production build to `.verify/frontend-build` instead of the source
tree. Maven `target/`, React `build/`, `node_modules/`, scanner workspaces, rendered
manifests, security reports, and local caches are generated artifacts and must remain
outside Git.

---

## 1. What Changed from v2

| Concern | v2 (Podman / Compose) | v3 (Kind / Kubernetes) |
|---|---|---|
| Orchestrator | `podman-compose` | Kubernetes (kind) |
| Cluster | single Podman network | single-node kind cluster |
| Manifest format | `docker-compose.yml` | Kubernetes YAML + Kustomize overlays |
| Ingress | host port binding | nginx Ingress Controller (port 80) |
| URL path routing | Nginx proxy blocks | API Ingress rewrite-target strips `/api` prefix |
| Secrets | `.env` file | Kubernetes `Secret` objects |
| Non-secret config | inline env in Compose | `ConfigMap` objects |
| Image delivery | `podman build` → local | `podman build` → `podman save \| kind load image-archive` |
| Storage | Podman named volume | PersistentVolumeClaim (kind `standard` StorageClass) |
| Service discovery | container DNS names | Kubernetes Service DNS (`<svc>.<ns>.svc.cluster.local`) |
| Base manifests | N/A | Kustomize `base/` — same YAMLs used in production (AWS) |
| Local overlay | N/A | `kubernetes/environments/kind/` — patches base for local dev |

---

## 2. Architecture

```
  Browser
    │ http://localhost
    ▼
┌─────────────────────────────────────────────────────────────────┐
│                  kind single-node cluster                        │
│                  context: kind-issue-app                         │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │            nginx Ingress Controller (host port 80)        │   │
│  │                                                          │   │
│  │  /api/* → strips /api → api-gateway:80                   │   │
│  │  /      → frontend-service:80                            │   │
│  └──────────────┬────────────────────────────────┬──────────┘   │
│                 │                                │              │
│     ┌───────────▼──────────┐         ┌──────────▼──────────┐   │
│     │  api-gateway         │         │  frontend-service    │   │
│     │  ClusterIP :80→8096  │         │  ClusterIP :80→3000  │   │
│     │  Spring Cloud GW     │         │  React dev server    │   │
│     │  profile: prod       │         │  REACT_APP_API==/api │   │
│     └────────┬─────────────┘         └─────────────────────┘   │
│              │                                                   │
│      /auth/**  /issues/**                                        │
│              │                                                   │
│     ┌────────┴────────────────┐                                 │
│     │                         │                                  │
│  ┌──▼──────────────┐  ┌──────▼──────────────┐                  │
│  │  auth-service    │  │  issue-service       │                  │
│  │  ClusterIP :80   │  │  ClusterIP :80       │                  │
│  │  →8097           │  │  →8098               │                  │
│  └──────┬───────────┘  └──────┬──────────────┘                  │
│         │                     │                                  │
│         └──────────┬──────────┘                                  │
│                    │ :3306                                        │
│         ┌──────────▼──────────┐                                  │
│         │  mysql              │                                   │
│         │  ClusterIP :3306    │                                   │
│         │  PVC: mysql-pvc     │                                   │
│         │  (standard / 1Gi)   │                                   │
│         └─────────────────────┘                                   │
│                                                                   │
│  Namespace: issue-app                                             │
│  ServiceAccount: issue-app-sa                                     │
└─────────────────────────────────────────────────────────────────┘
```

**Request flow detail:**

```
Browser  GET /api/auth/login
  → nginx Ingress (localhost:80)
  → rewrite: strip /api  →  /auth/login
  → api-gateway Service (ClusterIP :80)
  → api-gateway Pod (:8096)
  → route match: Path=/auth/**
  → auth-service Service (ClusterIP :80)
  → auth-service Pod (:8097)
```

---

## 3. Repository Layout

```
kubernetes/
├── base/                          # Mirrors production layout (AWS EKS)
│   ├── infrastructure/
│   │   ├── namespace.yaml         # Namespace: issue-app
│   │   ├── serviceaccount.yaml    # ServiceAccount with IRSA annotation (harmless in kind)
│   │   ├── ingress.yaml           # ALB Ingress (prod only — excluded from kind overlay)
│   │   └── secret-store.yaml      # ExternalSecretStore (prod only — excluded)
│   ├── services/
│   │   ├── api-gateway/           # Deployment, Service, ExternalSecret
│   │   ├── auth-service/          # Deployment, Service, ConfigMap, ExternalSecret
│   │   ├── issue-service/         # Deployment, Service, ConfigMap, ExternalSecret, PVC
│   │   └── frontend-service/      # Deployment, Service
│   └── kustomization.yaml
│
└── environments/
    └── kind/                      # Local dev overlay
        ├── kind-cluster.yaml      # kind cluster config (single node, port 80→80)
        ├── kustomization.yaml     # Selects from base + adds kind-specific resources
        ├── ingress.yaml           # frontend nginx Ingress (no rewrite)
        ├── api-ingress.yaml       # API nginx Ingress (strips /api)
        ├── secrets.yaml           # Plain K8s Secrets (replaces ExternalSecrets)
        ├── mysql/
        │   ├── deployment.yaml    # in-cluster MySQL 8.0
        │   ├── service.yaml       # ClusterIP :3306
        │   └── pvc.yaml           # PVC: mysql-pvc (standard StorageClass)
        └── patches/
            ├── configmap-auth.yaml        # Swap RDS URL → mysql:3306
            ├── configmap-issue.yaml       # Swap RDS URL → mysql:3306
            ├── pvc-storageclass.yaml      # gp2 → standard
            ├── deployment-api-gateway.yaml    # imagePullPolicy: Never + CORS
            ├── deployment-auth-service.yaml   # imagePullPolicy: Never + admin seed env
            ├── deployment-issue-service.yaml  # imagePullPolicy: Never
            └── deployment-frontend-service.yaml # imagePullPolicy: Never

scripts/
└── kind-deploy.sh     # One-shot: create cluster → build images → load → deploy
```

---

## 4. Prerequisites

Install all tools before proceeding.

### 4.1 kind

```bash
# macOS
brew install kind

# Linux
curl -Lo /usr/local/bin/kind \
  https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
chmod +x /usr/local/bin/kind

kind --version   # kind v0.23.x
```

### 4.2 kubectl

```bash
# macOS
brew install kubectl

# Linux
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

kubectl version --client   # Client Version: v1.3x.x
```

### 4.3 Podman

The `kind-deploy.sh` script uses **Podman** as the container runtime. Podman must be
installed and its machine must be running before executing any `kind` or build commands.

```bash
# macOS — install Podman
brew install podman

# Initialise and start the Podman machine (VM that runs containers)
podman machine init --cpus 4 --memory 8192 --disk-size 60
podman machine start

# Verify
podman info   # must succeed and show running state
podman machine list   # State: Currently running
```

> **Why Podman and not Docker?**
> kind v0.24+ supports Podman as a container runtime via the
> `KIND_EXPERIMENTAL_PROVIDER=podman` environment variable. The `kind-deploy.sh`
> script sets this automatically. On macOS, Podman runs containers inside an
> Apple Hypervisor VM and exposes `/var/run/docker.sock` for compatibility.

> **Note on Podman 5+/6+ compatibility:** kind's Podman provider uses `podman ps`
> with Go template syntax that changed in Podman 5. The script works around this by
> using `podman save <image> | kind load image-archive /dev/stdin` instead of
> `kind load docker-image`, which avoids the incompatible codepath.

### 4.4 kustomize (optional — kubectl has it built in)

```bash
# Verify kubectl has kustomize built in
kubectl kustomize --help   # should print usage

# Standalone (optional)
brew install kustomize
```

### 4.5 System requirements

| Resource | Minimum | Recommended |
|---|---|---|
| CPU | 2 cores | 4 cores |
| RAM | 6 GB free | 10 GB free |
| Disk | 10 GB free | 20 GB free |
| OS | Linux / macOS | Ubuntu 22.04 / macOS 14+ |

---

## 5. Quick Deploy — One Command

The `kind-deploy.sh` script handles everything end-to-end.

**Ensure Podman machine is running first:**

```bash
podman machine start
```

**Then run the script:**

```bash
git clone -b v3-deploy-in-kind \
  https://github.com/amitactive2008/sample-spring-boot-application.git
cd sample-spring-boot-application

chmod +x scripts/kind-deploy.sh
./scripts/kind-deploy.sh
```

What the script does (in order):

| Step | Action |
|---|---|
| 1 | Creates kind cluster `issue-app` using `KIND_EXPERIMENTAL_PROVIDER=podman` |
| 2 | Installs nginx Ingress Controller; waits via `kubectl rollout status` |
| 3 | Builds all 4 images with `podman build -t localhost/<name>:local` |
| 4 | Loads images into kind: `podman save <img> \| kind load image-archive /dev/stdin` |
| 5 | Applies Kustomize overlay: `kubectl kustomize ... --load-restrictor=LoadRestrictionsNone \| kubectl apply -f -` |
| 6 | Waits for MySQL pod to be ready |
| 7 | Waits for all application pods to be ready |

When complete:

```
════════════════════════════════════════════════
  Issue Tracker is running on kind!
════════════════════════════════════════════════

  Frontend  →  http://localhost
               http://microservices-ingress.localhost
  API       →  http://localhost/api

  Default admin credentials:
    Email:    admin@example.com
    Password: Admin1234!
════════════════════════════════════════════════
```

**Tear down:**

```bash
./scripts/kind-deploy.sh teardown
```

> **Existing clusters:** Kind port mappings are fixed at cluster creation. If the
> `issue-app` cluster was created with host port 8080, run the teardown command and
> then run `./scripts/kind-deploy.sh` again. Teardown deletes the cluster, including
> the in-cluster MySQL data, so export anything you need first.

---

## 6. Step-by-Step Manual Deploy

Use this section if you prefer fine-grained control or need to debug individual steps.

### 6.1 Create the kind cluster

Set the Podman provider and create the cluster:

```bash
export KIND_EXPERIMENTAL_PROVIDER=podman

kind create cluster \
  --name issue-app \
  --config kubernetes/environments/kind/kind-cluster.yaml

# Verify context is set
kubectl config current-context   # kind-issue-app
kubectl get nodes                # STATUS: Ready
```

### 6.2 Install nginx Ingress Controller

```bash
kubectl apply -f \
  https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Use rollout status — tolerates pods not yet scheduled (unlike kubectl wait)
kubectl rollout status deployment/ingress-nginx-controller \
  -n ingress-nginx \
  --timeout=120s

kubectl get pods -n ingress-nginx   # STATUS: Running
```

### 6.3 Build images with Podman

Images are tagged with the `localhost/` prefix because Podman qualifies all
unregistered image names with `localhost/`, and this is what ends up in
kind's containerd. The kustomization image overrides use the same prefix.

```bash
podman build -t localhost/auth-service:local     ./auth-service
podman build -t localhost/issue-service:local    ./issue-service
podman build -t localhost/api-gateway:local      ./api-gateway
podman build -t localhost/frontend-service:local ./frontend-service
```

### 6.4 Load images into the kind cluster

kind runs inside a Podman container — images in Podman's store are not
automatically visible inside the cluster. `kind load docker-image` requires
the Docker CLI; instead pipe through `podman save`:

```bash
for img in \
  localhost/api-gateway:local \
  localhost/auth-service:local \
  localhost/issue-service:local \
  localhost/frontend-service:local
do
  echo "Loading $img..."
  podman save "$img" | kind load image-archive /dev/stdin --name issue-app
done
```

Verify images are present in the cluster node:

```bash
podman exec issue-app-control-plane crictl images \
  | grep -E "auth|issue|gateway|frontend"
# Expected: localhost/auth-service   local  ...
```

### 6.5 Apply the Kustomize overlay

`kubectl apply -k` is blocked by Kustomize v5 security when patches reference
files via `../../base/` paths (outside the kustomization root). Use the
`--load-restrictor=LoadRestrictionsNone` flag instead:

```bash
# Preview what will be applied (dry-run)
kubectl kustomize kubernetes/environments/kind \
  --load-restrictor=LoadRestrictionsNone

# Apply for real
kubectl kustomize kubernetes/environments/kind \
  --load-restrictor=LoadRestrictionsNone \
  | kubectl apply -f -
```

### 6.6 Wait for pods to become ready

```bash
# MySQL must be ready before Spring services attempt DB connections
kubectl wait -n issue-app \
  --for=condition=ready pod \
  --selector=app=mysql \
  --timeout=180s

# All application services (Spring Boot starts in ~15-20s inside kind)
for svc in auth-service issue-service api-gateway frontend-service; do
  echo "Waiting for $svc..."
  kubectl wait -n issue-app \
    --for=condition=ready pod \
    --selector="app=$svc" \
    --timeout=300s
done
```

### 6.7 Open the application

```
http://localhost
```

For a readable hostname that still receives special localhost handling from browsers and
corporate network agents, use:

```text
http://microservices-ingress.localhost
```

The `.localhost` suffix resolves to `127.0.0.1` automatically, so no `/etc/hosts` entry is
needed. A plain custom `/etc/hosts` name may be intercepted by managed network software
such as Netskope. The Kind cluster publishes nginx Ingress on the standard HTTP port 80,
so no explicit port is needed in the URL.

Login: `admin@example.com` / `Admin1234!`

**Verify via CLI:**

```bash
# Gateway health
curl http://localhost/api/actuator/health

# Admin login
curl -X POST http://localhost/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@example.com","password":"Admin1234!"}'
```

---

## 7. Kustomize Overlay Explained

The `kubernetes/environments/kind/kustomization.yaml` is the heart of the local
deployment. It selectively pulls from `base/` and overrides what changes between
production (AWS EKS) and local (kind).

### 7.1 What is excluded from base

| Base resource | Why excluded from kind overlay |
|---|---|
| `infrastructure/secret-store.yaml` | Requires External Secrets Operator + AWS Secrets Manager |
| `infrastructure/ingress.yaml` | AWS ALB Ingress — replaced by `ingress.yaml` (nginx) |
| `services/*/external-secret.yaml` | Requires ESO — replaced by `secrets.yaml` |

### 7.2 What is added (kind-specific)

| Resource | Purpose |
|---|---|
| `mysql/deployment.yaml` | In-cluster MySQL 8.0 (replaces AWS RDS) |
| `mysql/service.yaml` | ClusterIP Service so pods reach MySQL at `mysql:3306` |
| `mysql/pvc.yaml` | 1 Gi PVC using `standard` StorageClass (kind built-in) |
| `secrets.yaml` | Plain `Secret` objects with dev credentials |
| `ingress.yaml` | Frontend nginx Ingress without path rewriting |
| `api-ingress.yaml` | API nginx Ingress that strips the public `/api` prefix |

### 7.3 Patches applied

| Patch file | What it changes |
|---|---|
| `patches/configmap-auth.yaml` | `SPRING_DATASOURCE_URL`: RDS → `mysql:3306` with `serverTimezone=UTC`; `MAIL_ENABLED` → false |
| `patches/configmap-issue.yaml` | Same DB URL swap for issue-service |
| `patches/pvc-storageclass.yaml` | `storageClassName`: gp2 → standard |
| `patches/service-auth.yaml` | Service port: 80 → **8097** (matches `http://auth-service:8097` in gateway routes) |
| `patches/service-issue.yaml` | Service port: 80 → **8098** (matches `http://issue-service:8098` in gateway routes) |
| `patches/deployment-api-gateway.yaml` | `imagePullPolicy: Never`; `CORS_ALLOWED_ORIGIN: http://localhost` |
| `patches/deployment-auth-service.yaml` | `imagePullPolicy: Never`; inject `APP_ADMIN_EMAIL/PASSWORD` from Secret; `SPRING_JPA_HIBERNATE_DDL_AUTO: update` (overrides prod validate — fresh DB has no tables) |
| `patches/deployment-issue-service.yaml` | `imagePullPolicy: Never`; `SPRING_JPA_HIBERNATE_DDL_AUTO: update` |
| `patches/deployment-frontend-service.yaml` | `imagePullPolicy: Never`; memory limit 256Mi → **1Gi** (react-scripts OOMKills at 256Mi); `NODE_OPTIONS=--max-old-space-size=512` |

### 7.4 Image overrides

```yaml
images:
  - name: auth-service
    newName: localhost/auth-service   # Podman qualifies local images with localhost/
    newTag: local
```

`imagePullPolicy: Never` + `newName: localhost/<name>` + `newTag: local` ensures
Kubernetes uses the image loaded via `podman save | kind load image-archive` and
never attempts to pull from an external registry.

### 7.5 Ingress path rewrite

The frontend's `REACT_APP_API_BASE_URL=/api` means every API call is prefixed with
`/api` (e.g., `/api/auth/login`). The API nginx Ingress strips this prefix before
forwarding to the gateway, which expects `/auth/login`:

```yaml
metadata:
  name: microservices-api-ingress
annotations:
  nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  rules:
    - http:
        paths:
          - path: /api(/|$)(.*)      # capture group $2 = everything after /api
            backend:
              service:
                name: api-gateway
                port:
                  number: 80
```

The frontend `/` route is defined in the separate `microservices-ingress` resource
without a rewrite annotation. nginx annotations apply to every path in one Ingress;
combining these routes would rewrite `/static/js/bundle.js` to `/` and return HTML
instead of JavaScript.

---

## 8. Kubernetes Resources Reference

All resources live in namespace `issue-app`.

| Kind | Name | Description |
|---|---|---|
| Namespace | `issue-app` | Isolates all workloads |
| ServiceAccount | `issue-app-sa` | Shared SA for all pods (IRSA annotation is harmless in kind) |
| Secret | `api-gateway-secrets` | `JWT_SECRET` |
| Secret | `auth-service-secrets` | DB creds, JWT secret, SES placeholders, admin seed |
| Secret | `issue-service-secrets` | DB creds, JWT secret |
| ConfigMap | `auth-service-config` | `SPRING_DATASOURCE_URL`, `MAIL_ENABLED` |
| ConfigMap | `issue-service-config` | `SPRING_DATASOURCE_URL` |
| Deployment | `mysql` | MySQL 8.0, `Recreate` strategy |
| Deployment | `auth-service` | Spring Boot 4.x, 1 replica |
| Deployment | `issue-service` | Spring Boot 4.x, 1 replica |
| Deployment | `api-gateway` | Spring Cloud Gateway 3.x, 1 replica |
| Deployment | `frontend-service` | React dev server (Node 20), 1 replica |
| Service | `mysql` | ClusterIP `:3306` |
| Service | `auth-service` | ClusterIP `:80 → 8097` |
| Service | `issue-service` | ClusterIP `:80 → 8098` |
| Service | `api-gateway` | ClusterIP `:80 → 8096` |
| Service | `frontend-service` | ClusterIP `:80 → 3000` |
| PVC | `mysql-pvc` | 1 Gi, `standard` StorageClass |
| PVC | `issue-storage-pvc` | `standard` StorageClass |
| Ingress | `microservices-api-ingress` | nginx, `/api/*` → gateway with `/api` stripped |
| Ingress | `microservices-ingress` | nginx, `/` → frontend without rewriting static assets |

Resource limits per pod:

| Pod | CPU request/limit | Memory request/limit |
|---|---|---|
| mysql | 250m / 500m | 512Mi / 1Gi |
| auth-service | 250m / 500m | 512Mi / 1Gi |
| issue-service | 250m / 500m | 512Mi / 1Gi |
| api-gateway | 250m / 500m | 512Mi / 1Gi |
| frontend-service | 100m / 200m | 128Mi / 256Mi |

---

## 9. Verify the Deployment

### 9.1 Check all pods

```bash
kubectl get pods -n issue-app -o wide
```

All pods must be in `Running` state with `1/1` READY:

```
NAME                                READY   STATUS    RESTARTS
api-gateway-xxxxxxxxx-xxxxx         1/1     Running   0
auth-service-xxxxxxxxx-xxxxx        1/1     Running   0
frontend-service-xxxxxxxxx-xxxxx    1/1     Running   0
issue-service-xxxxxxxxx-xxxxx       1/1     Running   0
mysql-xxxxxxxxx-xxxxx               1/1     Running   0
```

### 9.2 Check Services and Ingress

```bash
kubectl get svc,ingress -n issue-app
```

### 9.3 API smoke tests

```bash
HOST=http://localhost

# Register
curl -s -X POST $HOST/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"tester@example.com","password":"Test@1234"}'

# Login — capture token
TOKEN=$(curl -s -X POST $HOST/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@example.com","password":"Admin1234!"}' \
  | jq -r '.accessToken')

echo "JWT: ${TOKEN:0:50}..."

# Create an issue
curl -s -X POST $HOST/api/issues \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title":"Kind smoke test","priority":"HIGH","severity":"MEDIUM"}'

# List issues
curl -s "$HOST/api/issues" \
  -H "Authorization: Bearer $TOKEN" | jq '.content[].title'
```

### 9.4 Open UI

```
http://localhost
```

---

## 10. Day-2 Operations

### View live logs

```bash
kubectl logs -n issue-app deploy/auth-service   -f
kubectl logs -n issue-app deploy/issue-service  -f
kubectl logs -n issue-app deploy/api-gateway    -f
kubectl logs -n issue-app deploy/mysql          -f
```

### Exec into a pod

```bash
# MySQL shell
kubectl exec -n issue-app -it deploy/mysql -- \
  mysql -u game_admin -pdevpassword123 game_db

# Auth service shell
kubectl exec -n issue-app -it deploy/auth-service -- sh
```

### Describe a failing pod

```bash
kubectl describe pod -n issue-app -l app=auth-service
kubectl get events -n issue-app --sort-by='.lastTimestamp'
```

### Rebuild and redeploy a single service

```bash
# Rebuild with Podman (localhost/ prefix required — see §6.3)
podman build -t localhost/auth-service:local ./auth-service

# Reload into kind via image archive
podman save localhost/auth-service:local \
  | kind load image-archive /dev/stdin --name issue-app

# Restart the deployment (triggers a rolling update)
kubectl rollout restart -n issue-app deploy/auth-service

# Watch rollout
kubectl rollout status -n issue-app deploy/auth-service
```

### Update Secrets without redeploying

```bash
# Edit the secret in-place
kubectl edit secret -n issue-app auth-service-secrets

# Or patch a specific key (base64-encode the value)
JWT=$(echo -n "MyNewJWTSecret32chars!!!!!!!!!!!" | base64)
kubectl patch secret -n issue-app auth-service-secrets \
  -p "{\"data\":{\"JWT_SECRET\":\"$JWT\"}}"

# Restart pods to pick up the new secret
kubectl rollout restart -n issue-app deploy/auth-service deploy/issue-service deploy/api-gateway
```

### View resource usage

```bash
kubectl top pods -n issue-app
kubectl top nodes
```

---

## 11. Tear Down

```bash
# Delete all Kubernetes resources and the cluster
./scripts/kind-deploy.sh teardown

# Or manually
kind delete cluster --name issue-app
```

---

## 12. Security & Code Quality Pipeline

v3 inherits the **entire security pipeline from v2** (Gitleaks, Hadolint, Checkstyle,
Semgrep, Maven Build, NVD Check, Lint, Trivy image + config, SonarQube, Quality Gate,
DAST) and adds **two Kubernetes-specific layers**:

- **Kubesec** — security risk scoring of Kubernetes manifests
- **kube-score** — Kubernetes best-practice analysis (resources, probes, security context)
- **Trivy config extended** — Kubernetes YAML scanning (`KSV` ruleset)

```
Developer push / Pull Request
          │
          ▼
  ┌───────────────┐
  │  1. Gitleaks  │  ← secrets in git / secrets.yaml accidentally real?
  └───────┬───────┘
          ▼
  ┌────────────────┐
  │  2. Hadolint   │  ← Dockerfile best-practice lint (all 4 Dockerfiles)
  └───────┬────────┘
          ▼
  ┌──────────────────────┐
  │  3. Trivy config     │  ← Dockerfiles + docker-compose.yml + K8s YAML
  │  (pre-build)         │     DS* (Dockerfile) + KSV* (Kubernetes) rules
  └──────────┬───────────┘
          ▼
  ┌─────────────────┐
  │  4. Kubesec     │  ← Security risk score for each K8s manifest
  └───────┬─────────┘
          ▼
  ┌─────────────────┐
  │  5. kube-score  │  ← K8s best-practice: probes, resources, securityContext
  └───────┬─────────┘
          ▼
  ┌────────────────┐
  │  6. Checkstyle │  ← Java code style
  └───────┬────────┘
          ▼
  ┌──────────────┐
  │  7. Semgrep  │  ← SAST: Java + JS + Dockerfile patterns
  └──────┬───────┘
          ▼
  ┌──────────────────────────────────────┐
  │  8. Maven Build -DskipTests -B       │  ← compile + package
  └──────────────────┬───────────────────┘
          ▼
  ┌──────────────────┐
  │  9. NVD Check    │  ← OWASP Dep-Check (JARs) + npm audit
  └──────┬───────────┘
          ▼
  ┌──────────────┐
  │  10. Lint    │  ← ESLint + SpotBugs
  └──────┬───────┘
          ▼
  ┌─────────────────────┐
  │  11. podman build   │  ← Build all 4 images (local) / docker build (CI)
  └──────────┬──────────┘
          ▼
  ┌──────────────────┐
  │  12. Trivy image │  ← OS + lib CVEs + secrets in image layers
  └──────┬───────────┘
          ▼
  ┌─────────────┐
  │ 13. Sonar   │  ← deep quality + security analysis
  └──────┬──────┘
          ▼
  ┌────────────────┐
  │ 14. Quality    │  ← pass/fail threshold — blocks merge
  │     Gate       │
  └──────┬─────────┘
          │
       MERGE
          │
     Deploy to kind staging
          │
          ▼
  ┌──────────────────┐
  │  15. DAST Audit  │  ← OWASP ZAP against running kind cluster
  └──────────────────┘
```

---

### 12.1 Gitleaks — Secret Scanning

Same as v2, with one additional risk: `kubernetes/environments/kind/secrets.yaml`
contains plain-text Kubernetes Secret values. Gitleaks will flag if real credentials
are committed there instead of the dummy dev values.

```bash
gitleaks detect --source . --verbose
```

Add to `.gitleaks.toml` to suppress known dev dummy values:

```toml
[allowlist]
description = "Suppress kind dev dummy secrets"
regexes = [
  "local-kind-jwt-secret-key-32bytes!!",
  "devpassword123",
  "rootpassword",
  "disabled",
  "Admin1234!"
]
```

**Critical rule:** `kubernetes/environments/kind/secrets.yaml` must only ever contain
dev/dummy credentials. Production secrets live exclusively in AWS Secrets Manager
via ExternalSecrets — never in git.

---

### 12.2 Hadolint — Dockerfile Linting

Unchanged from v2. Lint all four Dockerfiles:

```bash
find . -name "Dockerfile" | xargs hadolint --failure-threshold warning
```

See v2 README Section 10.2 for the full list of findings and the hardened Dockerfile
template with non-root user and `HEALTHCHECK`.

---

### 12.3 Trivy Config — Extended to Kubernetes Manifests

In v3, `trivy config` scans **three target types**:
1. Dockerfiles (`DS*` rules) — same as v2
2. `docker-compose.yml` (`KSV*` Compose rules) — same as v2
3. **Kubernetes YAML manifests** (`KSV*` Kubernetes rules) — new in v3

#### Scan Kubernetes manifests

```bash
# Scan all K8s YAML in the kubernetes/ directory
trivy config \
  --exit-code 1 \
  --severity HIGH,CRITICAL \
  --misconfiguration-scanners terraform,cloudformation,dockerfile,kubernetes \
  kubernetes/

# Or include the whole repo (Trivy auto-detects file types)
trivy config \
  --exit-code 1 \
  --severity HIGH,CRITICAL \
  .
```

#### What Trivy's `KSV` rules will flag in this project's K8s manifests

| Check | Severity | Manifest | Finding | Fix |
|---|---|---|---|---|
| KSV001 | HIGH | all Deployments | No `securityContext.allowPrivilegeEscalation: false` | Add to each container spec |
| KSV003 | LOW | all Deployments | No `securityContext.capabilities.drop: [ALL]` | Drop all Linux capabilities |
| KSV011 | LOW | mysql Deployment | No CPU limit | Already set — verify in manifest |
| KSV014 | LOW | all Deployments | `readOnlyRootFilesystem` not set to `true` | Add to container securityContext |
| KSV017 | HIGH | all Deployments | Privilege escalation allowed | Set `allowPrivilegeEscalation: false` |
| KSV020 | LOW | all Deployments | Container runs as root (no `runAsNonRoot`) | Set `runAsNonRoot: true` |
| KSV030 | LOW | all Deployments | No `securityContext.seccompProfile` | Set `seccompProfile.type: RuntimeDefault` |

#### Recommended `securityContext` additions to all Deployment pod specs

Add to each container in the Deployments (example for `auth-service`):

```yaml
# kubernetes/base/services/auth-service/deployment.yaml
spec:
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 2000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: auth-service
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
```

Spring Boot needs `/tmp` for temp files when `readOnlyRootFilesystem: true`:

```yaml
          volumeMounts:
            - name: tmp-dir
              mountPath: /tmp
      volumes:
        - name: tmp-dir
          emptyDir: {}
```

#### Output formats for K8s config scan

```bash
# JSON — for pipeline artifact or parsing
trivy config --format json --output trivy-k8s-config.json kubernetes/

# SARIF — for GitHub Security tab
trivy config --format sarif --output trivy-k8s-config.sarif kubernetes/
```

---

### 12.4 Kubesec — Kubernetes Manifest Security Risk Scoring

**What it is:**
Kubesec analyses Kubernetes resource manifests and produces a security risk score (0–10+).
It checks for security context settings, privilege escalation, host namespace access,
capability dropping, and seccomp profiles — and explains exactly why each point was
deducted or awarded.

**SDLC value:**
Kubesec provides a quantitative score per manifest rather than a simple pass/fail. This
means the team can track security posture improvement sprint-over-sprint. A score below
a defined threshold blocks the pipeline, forcing manifests to improve before merge.

**How to apply:**

Install:
```bash
# macOS
brew install kubesec

# Linux / Docker
docker pull kubesec/kubesec:v2

# Or download binary
curl -sSL https://github.com/controlplaneio/kubesec/releases/latest/download/kubesec_linux_amd64.tar.gz \
  | tar -xz && sudo mv kubesec /usr/local/bin/
```

Scan a single manifest:
```bash
kubesec scan kubernetes/base/services/auth-service/deployment.yaml
```

Sample output:
```json
[
  {
    "object": "Deployment/auth-service.issue-app",
    "valid": true,
    "fileName": "deployment.yaml",
    "message": "Passed with a score of 0 points",
    "score": 0,
    "scoring": {
      "critical": [
        {
          "id": "AllowPrivilegeEscalation",
          "selector": "containers[] .securityContext .allowPrivilegeEscalation == false",
          "reason": "Force the running image to run as a non-root user to ensure least privilege",
          "points": -7
        }
      ],
      "advise": [
        {
          "id": "SeccompAny",
          "selector": ".metadata .annotations .\"seccomp.security.alpha.kubernetes.io/pod\"",
          "reason": "Seccomp profiles set minimum privilege and secure against unknown threats",
          "points": 1
        }
      ]
    }
  }
]
```

Scan all Deployment manifests and fail if score is below threshold:
```bash
#!/bin/bash
MIN_SCORE=0   # any negative score fails — raise to 3 once manifests are hardened
PASS=true

for MANIFEST in $(find kubernetes/ -name "deployment.yaml"); do
  echo "=== Scanning: $MANIFEST ==="
  SCORE=$(kubesec scan "$MANIFEST" | jq '.[0].score')
  echo "  Score: $SCORE"
  if [ "$SCORE" -lt "$MIN_SCORE" ]; then
    echo "  FAIL — score $SCORE is below minimum $MIN_SCORE"
    PASS=false
  fi
done

$PASS || exit 1
```

Scan via Docker (no binary install needed in CI):
```bash
docker run --rm -v $(pwd):/workspace kubesec/kubesec:v2 \
  scan /workspace/kubernetes/base/services/auth-service/deployment.yaml
```

**Expected scores for the current manifests** (pre-hardening):
All deployments will score **below 0** (negative) because `allowPrivilegeEscalation`
is not set. After applying the `securityContext` additions from Section 12.3, scores
improve to **+3 to +5**.

---

### 12.5 kube-score — Kubernetes Best-Practice Analysis

**What it is:**
kube-score reads Kubernetes YAML manifests and checks them against a curated list of
best practices covering reliability (liveness/readiness probes, pod disruption budgets),
resource management (requests and limits), and security (securityContext, network
policies, image tag pinning).

**SDLC value:**
While Trivy and Kubesec focus on security vulnerabilities and risk scores, kube-score
focuses on operational best practices that directly impact availability and security.
Missing readiness probes cause traffic to reach pods that are not ready; missing resource
limits allow one pod to starve others; using `imagePullPolicy: Always` with `:latest`
tags causes unpredictable deployments.

**How to apply:**

Install:
```bash
# macOS
brew install kube-score

# Linux
curl -Lo /usr/local/bin/kube-score \
  https://github.com/zegl/kube-score/releases/latest/download/kube-score_linux_amd64
chmod +x /usr/local/bin/kube-score
```

Score all manifests in the kind overlay:
```bash
# Render the full kustomization and pipe to kube-score
kubectl kustomize kubernetes/environments/kind | kube-score score -
```

Score individual manifests:
```bash
kube-score score kubernetes/base/services/auth-service/deployment.yaml
kube-score score kubernetes/environments/kind/mysql/deployment.yaml
```

Fail the pipeline on any `CRITICAL` finding:
```bash
kubectl kustomize kubernetes/environments/kind \
  | kube-score score --exit-one-on-error -
```

**What kube-score will flag in this project:**

| Check | Severity | Finding | Fix |
|---|---|---|---|
| `container-security-context` | CRITICAL | No `securityContext` on any container | Add `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true` |
| `pod-probes` | WARNING | auth-service and issue-service have no `livenessProbe` or `readinessProbe` | Add Spring Actuator health probes |
| `container-image-tag` | WARNING | Base manifests use `:latest` tags | Pin to `sha256:` digest in production |
| `network-policy` | WARNING | No `NetworkPolicy` restricting pod-to-pod traffic | Add NetworkPolicy per service |
| `pod-disruption-budget` | WARNING | No `PodDisruptionBudget` | Add for stateful services |

**Adding readiness/liveness probes** to auth-service and issue-service
(Spring Boot Actuator is already on the classpath):

```yaml
containers:
  - name: auth-service
    readinessProbe:
      httpGet:
        path: /actuator/health/readiness
        port: 8097
      initialDelaySeconds: 30
      periodSeconds: 10
      failureThreshold: 3
    livenessProbe:
      httpGet:
        path: /actuator/health/liveness
        port: 8097
      initialDelaySeconds: 60
      periodSeconds: 15
      failureThreshold: 5
```

---

### 12.6 Checkstyle, Semgrep, Maven Build, NVD Check, Lint

Unchanged from v2. Run against the Java source and React source before building images.
Refer to v2 README Sections 10.3–10.7 for full configuration details.

```bash
# Checkstyle
cd auth-service  && ./mvnw checkstyle:check && cd ..
cd issue-service && ./mvnw checkstyle:check && cd ..
cd api-gateway   && ./mvnw checkstyle:check && cd ..

# Semgrep (add p/kubernetes for K8s YAML security patterns)
semgrep --config p/spring-security --config p/java \
        --config p/javascript --config p/react \
        --config p/dockerfile --config p/kubernetes \
        --error .

# Maven build
cd auth-service  && ./mvnw clean package -DskipTests -B && cd ..
cd issue-service && ./mvnw clean package -DskipTests -B && cd ..
cd api-gateway   && ./mvnw clean package -DskipTests -B && cd ..

# NVD Check
cd auth-service  && ./mvnw dependency-check:check && cd ..
cd issue-service && ./mvnw dependency-check:check && cd ..
cd api-gateway   && ./mvnw dependency-check:check && cd ..
cd frontend-service && npm audit --audit-level=high && cd ..

# Lint
cd frontend-service && npm run lint && cd ..
cd auth-service     && ./mvnw spotbugs:check && cd ..
cd issue-service    && ./mvnw spotbugs:check && cd ..
```

> Add `p/kubernetes` to the Semgrep config — it catches YAML anti-patterns like
> `hostNetwork: true`, `privileged: true`, and mounting the Docker socket.

---

### 12.7 Trivy Image Scan

Unchanged from v2. Build images and scan each one:

```bash
# Build
docker build -t auth-service:ci    ./auth-service
docker build -t issue-service:ci   ./issue-service
docker build -t api-gateway:ci     ./api-gateway
docker build -t frontend-service:ci ./frontend-service

# Scan all images
for IMAGE in auth-service issue-service api-gateway frontend-service; do
  trivy image \
    --exit-code 1 \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    --scanners vuln,secret \
    --no-progress \
    "${IMAGE}:ci"
done
```

See v2 README Section 10.9 for all flags, output formats, Podman integration, DB caching,
and `.trivyignore` suppression configuration.

---

### 12.8 SonarQube and Quality Gate

Unchanged from v2. Run Maven Sonar analysis after the build step, then poll the Quality
Gate result.

Refer to v2 README Sections 10.10–10.11 for SonarQube Docker setup, project properties,
analysis commands, and gate condition table.

---

### 12.9 DAST Audit — Against the Running Kind Cluster

In v3, DAST runs against the kind cluster via `localhost` on the standard nginx Ingress HTTP port.

```bash
# Ensure kind cluster is up and all pods ready
kubectl get pods -n issue-app

# Get admin JWT for authenticated scan
TOKEN=$(curl -s -X POST http://localhost/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@example.com","password":"Admin1234!"}' \
  | jq -r '.accessToken')

# Baseline passive scan against the frontend
docker run --rm --network host ghcr.io/zaproxy/zaproxy:stable \
  zap-baseline.py \
  -t http://localhost \
  -r zap-kind-baseline.html \
  -I

# API active scan against the gateway
docker run --rm --network host ghcr.io/zaproxy/zaproxy:stable \
  zap-api-scan.py \
  -t http://localhost/api \
  -f openapi \
  -r zap-kind-api.html
```

---

### Security Pipeline — Quick Reference (v3)

| # | Tool | Stage | Scope | Blocks? |
|---|---|---|---|---|
| 1 | **Gitleaks** | Pre-commit / CI | Git history; `secrets.yaml` leak | Yes |
| 2 | **Hadolint** | CI — pre-build | 4 Dockerfiles | Yes |
| 3 | **Trivy config** | CI — pre-build | Dockerfiles + Compose + **K8s YAML** (KSV rules) | Yes |
| 4 | **Kubesec** | CI — pre-build | K8s Deployment manifests (risk score) | Yes (score < threshold) |
| 5 | **kube-score** | CI — pre-build | K8s manifests (probes, resources, securityContext) | Yes (CRITICAL findings) |
| 6 | **Checkstyle** | CI — validate | Java source style | Yes |
| 7 | **Semgrep** | CI — SAST | Java + JS + Dockerfile + **K8s YAML** patterns | Yes |
| 8 | **Maven Build** | CI — compile | 3 Spring Boot services | Yes |
| 9 | **NVD Check** | CI — SCA | JARs + npm packages | Yes (CVSS ≥ 7) |
| 10 | **Lint** | CI | ESLint (React) + SpotBugs (Java) | Yes |
| 11 | **docker build** | CI — image build | 4 container images | Yes |
| 12 | **Trivy image** | CI — image scan | OS packages + libs + secrets in layers | Yes (HIGH/CRIT) |
| 13 | **SonarQube** | CI — analysis | All services + frontend | Yes |
| 14 | **Quality Gate** | CI — gate | SonarQube metric thresholds | Yes |
| 15 | **DAST Audit** | Post-deploy kind | Running cluster via `localhost` | Blocks promotion |

---

### Full CI Pipeline — GitHub Actions Skeleton (v3)

```yaml
name: CI Pipeline — v3 (Kind / Kubernetes)

on: [push, pull_request]

env:
  CLUSTER_NAME: issue-app
  NAMESPACE: issue-app

jobs:
  pipeline:
    runs-on: ubuntu-latest
    steps:

      # ── Checkout ────────────────────────────────────────────────────────────
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }

      # ── 1. Gitleaks ──────────────────────────────────────────────────────────
      - name: Gitleaks
        uses: gitleaks/gitleaks-action@v2

      # ── 2. Hadolint ──────────────────────────────────────────────────────────
      - name: Hadolint — all Dockerfiles
        run: |
          find . -name "Dockerfile" \
            | xargs docker run --rm -i hadolint/hadolint hadolint \
              --failure-threshold warning

      # ── 3. Trivy config — Dockerfiles + Compose + K8s YAML ──────────────────
      - name: Trivy config scan
        run: |
          curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
            | sh -s -- -b /usr/local/bin
          trivy config \
            --exit-code 1 \
            --severity HIGH,CRITICAL \
            --format sarif \
            --output trivy-config.sarif \
            --no-progress \
            .
      - name: Upload Trivy config SARIF
        uses: github/codeql-action/upload-sarif@v3
        if: always()
        with:
          sarif_file: trivy-config.sarif
          category: trivy-config

      # ── 4. Kubesec ───────────────────────────────────────────────────────────
      - name: Kubesec — K8s manifest risk scoring
        run: |
          curl -sSL https://github.com/controlplaneio/kubesec/releases/latest/download/kubesec_linux_amd64.tar.gz \
            | tar -xz && sudo mv kubesec /usr/local/bin/
          PASS=true
          for MANIFEST in $(find kubernetes/ -name "deployment.yaml"); do
            SCORE=$(kubesec scan "$MANIFEST" | jq '.[0].score')
            echo "$MANIFEST → score: $SCORE"
            [ "$SCORE" -ge 0 ] || PASS=false
          done
          $PASS || exit 1

      # ── 5. kube-score ────────────────────────────────────────────────────────
      - name: kube-score — K8s best-practice analysis
        run: |
          curl -Lo /usr/local/bin/kube-score \
            https://github.com/zegl/kube-score/releases/latest/download/kube-score_linux_amd64
          chmod +x /usr/local/bin/kube-score
          kubectl kustomize kubernetes/environments/kind \
            | kube-score score --exit-one-on-error -

      # ── 6 & 8. Checkstyle + Maven Build ──────────────────────────────────────
      - uses: actions/setup-java@v4
        with: { java-version: '17', distribution: 'temurin' }
      - name: Build auth-service (checkstyle + package)
        run: ./mvnw clean package -DskipTests -B
        working-directory: auth-service
      - name: Build issue-service
        run: ./mvnw clean package -DskipTests -B
        working-directory: issue-service
      - name: Build api-gateway
        run: ./mvnw clean package -DskipTests -B
        working-directory: api-gateway

      # ── 7. Semgrep SAST ──────────────────────────────────────────────────────
      - name: Semgrep SAST (Java + JS + Dockerfile + K8s)
        run: |
          pip install semgrep
          semgrep \
            --config p/spring-security \
            --config p/java \
            --config p/owasp-top-ten \
            --config p/javascript \
            --config p/react \
            --config p/dockerfile \
            --config p/kubernetes \
            --error .

      # ── 9. NVD Check ─────────────────────────────────────────────────────────
      - name: NVD Check — auth-service
        run: ./mvnw dependency-check:check
        working-directory: auth-service
        env: { NVD_API_KEY: "${{ secrets.NVD_API_KEY }}" }
      - name: NVD Check — issue-service
        run: ./mvnw dependency-check:check
        working-directory: issue-service
        env: { NVD_API_KEY: "${{ secrets.NVD_API_KEY }}" }
      - name: NVD Check — api-gateway
        run: ./mvnw dependency-check:check
        working-directory: api-gateway
        env: { NVD_API_KEY: "${{ secrets.NVD_API_KEY }}" }
      - uses: actions/setup-node@v4
        with: { node-version: '18' }
      - run: npm ci
        working-directory: frontend-service
      - name: npm audit
        run: npm audit --audit-level=high
        working-directory: frontend-service

      # ── 10. Lint ─────────────────────────────────────────────────────────────
      - name: ESLint
        run: npm run lint
        working-directory: frontend-service
      - name: SpotBugs
        run: ./mvnw spotbugs:check
        working-directory: auth-service

      # ── 11. Build container images ───────────────────────────────────────────
      - name: Build Docker images
        run: |
          docker build -t auth-service:ci    ./auth-service
          docker build -t issue-service:ci   ./issue-service
          docker build -t api-gateway:ci     ./api-gateway
          docker build -t frontend-service:ci ./frontend-service

      # ── 12. Trivy image scan ─────────────────────────────────────────────────
      - name: Cache Trivy DB
        uses: actions/cache@v4
        with:
          path: ~/.cache/trivy
          key: trivy-db-${{ github.run_id }}
          restore-keys: trivy-db-
      - name: Download Trivy DB
        run: trivy image --download-db-only --no-progress --cache-dir ~/.cache/trivy
      - name: Trivy image — auth-service
        run: |
          trivy image \
            --exit-code 1 --severity HIGH,CRITICAL \
            --ignore-unfixed --scanners vuln,secret \
            --format sarif --output trivy-auth.sarif \
            --cache-dir ~/.cache/trivy --no-progress \
            auth-service:ci
      - name: Trivy image — issue-service
        run: |
          trivy image \
            --exit-code 1 --severity HIGH,CRITICAL \
            --ignore-unfixed --scanners vuln,secret \
            --format sarif --output trivy-issues.sarif \
            --cache-dir ~/.cache/trivy --no-progress \
            issue-service:ci
      - name: Trivy image — api-gateway
        run: |
          trivy image \
            --exit-code 1 --severity HIGH,CRITICAL \
            --ignore-unfixed --scanners vuln,secret \
            --format sarif --output trivy-gateway.sarif \
            --cache-dir ~/.cache/trivy --no-progress \
            api-gateway:ci
      - name: Trivy image — frontend
        run: |
          trivy image \
            --exit-code 1 --severity HIGH,CRITICAL \
            --ignore-unfixed --scanners vuln,secret \
            --format sarif --output trivy-frontend.sarif \
            --cache-dir ~/.cache/trivy --no-progress \
            frontend-service:ci
      - name: Upload Trivy image SARIFs
        uses: github/codeql-action/upload-sarif@v3
        if: always()
        with:
          sarif_file: trivy-auth.sarif
          category: trivy-image-auth

      # ── 13 & 14. SonarQube + Quality Gate ───────────────────────────────────
      - name: SonarQube analysis
        run: |
          ./mvnw sonar:sonar \
            -Dsonar.host.url=${{ secrets.SONAR_HOST }} \
            -Dsonar.login=${{ secrets.SONAR_TOKEN }} \
            -Dsonar.projectKey=issue-tracker-auth-v3
        working-directory: auth-service
      - name: Quality Gate check
        run: |
          STATUS=$(curl -s -u ${{ secrets.SONAR_TOKEN }}: \
            "${{ secrets.SONAR_HOST }}/api/qualitygates/project_status?projectKey=issue-tracker-auth-v3" \
            | jq -r '.projectStatus.status')
          echo "Quality Gate: $STATUS"
          [ "$STATUS" = "OK" ] || exit 1

      # ── Load images into kind + deploy ───────────────────────────────────────
      - name: Create kind cluster
        if: github.ref == 'refs/heads/main'
        run: |
          go install sigs.k8s.io/kind@latest
          kind create cluster --name $CLUSTER_NAME \
            --config kubernetes/environments/kind/kind-cluster.yaml
          kubectl apply -f \
            https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
          kubectl wait --namespace ingress-nginx \
            --for=condition=ready pod \
            --selector=app.kubernetes.io/component=controller \
            --timeout=90s
      - name: Load images into kind
        if: github.ref == 'refs/heads/main'
        run: |
          docker tag auth-service:ci    auth-service:local
          docker tag issue-service:ci   issue-service:local
          docker tag api-gateway:ci     api-gateway:local
          docker tag frontend-service:ci frontend-service:local
          kind load docker-image auth-service:local    --name $CLUSTER_NAME
          kind load docker-image issue-service:local   --name $CLUSTER_NAME
          kind load docker-image api-gateway:local     --name $CLUSTER_NAME
          kind load docker-image frontend-service:local --name $CLUSTER_NAME
      - name: Deploy to kind
        if: github.ref == 'refs/heads/main'
        run: |
          kubectl kustomize kubernetes/environments/kind \
            --load-restrictor=LoadRestrictionsNone \
          | kubectl apply -f -

  # ── 15. DAST — runs against the kind staging cluster ──────────────────────
  dast:
    needs: pipeline
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Wait for cluster
        run: |
          kubectl wait -n issue-app --for=condition=ready pod \
            --selector=app=auth-service --timeout=300s
      - name: OWASP ZAP — Kind cluster
        uses: zaproxy/action-baseline@v0.12.0
        with:
          target: http://localhost
          fail_action: true

```

---

### Required Secrets (GitHub Actions)

| Secret | Description |
|---|---|
| `NVD_API_KEY` | Free from https://nvd.nist.gov/developers/request-an-api-key |
| `SONAR_HOST` | SonarQube server URL |
| `SONAR_TOKEN` | SonarQube analysis token |

---

## 13. Automated Pipeline Script — `security-pipeline.sh`

`security-pipeline.sh` at the repository root runs the complete 15-step pipeline
from Section 12 with a single command. It covers all v2 checks plus the three
Kubernetes-specific checks added in v3 (Trivy K8s config, Kubesec, kube-score).

It is intended to run on the **developer's workstation or a CI agent** — not
inside the Kind cluster.

### 13.1 What it covers

| Step | Tool | v3-specific? |
|---|---|---|
| 12.1 | Gitleaks — secret scanning | — |
| 12.2 | Hadolint — Dockerfile lint | — |
| 12.3 | Trivy config — Dockerfiles + **Kubernetes YAML** | **Extended in v3** |
| 12.4 | Kubesec — K8s manifest security scoring | **New in v3** |
| 12.5 | kube-score — K8s best-practice analysis | **New in v3** |
| 12.6 | Checkstyle, Semgrep, Maven Build, NVD Check, Lint | — |
| 12.7 | Podman Build + Trivy image scan | — |
| 12.8 | SonarQube + Quality Gate | — |
| 12.9 | DAST — ZAP against the running kind cluster | **URL: http://localhost** |

> **kubesec note:** The official `kubesec/kubesec:v2` Docker image has no ARM64
> variant. The script uses the free public API at `https://v2.kubesec.io/scan`
> instead, which works on any architecture. Kubesec and kube-score findings are
> **non-blocking** — they are logged as tech debt (add `securityContext` to
> resolve, see README §12.3–12.5).

### 13.2 Prerequisites

The script installs any missing tool automatically via `brew` (macOS) or binary download.

| Tool | Auto-installed? | Used for |
|---|---|---|
| `gitleaks` | Yes — GitHub binary release | 12.1 |
| `hadolint` | Yes — `brew install hadolint` | 12.2 |
| `trivy` | Yes — `brew install trivy` | 12.3, 12.7 |
| `kube-score` | Yes — `brew install kube-score` | 12.5 |
| `semgrep` | Yes — `pip3 install semgrep` | 12.6 |
| `jq` | Yes — `brew install jq` | JSON parsing |
| `node` / `npm` | Yes — `brew install node` | 12.6 ESLint |
| `podman` | Must be installed + machine running | 12.7, 12.8, 12.9 |
| `kubectl` | Must be installed | 12.5 kustomize render |
| `kubesec` | Public API — no install needed | 12.4 |

### 13.3 Usage

```bash
chmod +x security-pipeline.sh
./security-pipeline.sh [OPTIONS]
```

| Option | Description |
|---|---|
| _(no options)_ | Full 15-step pipeline — installs missing tools, runs everything |
| `--skip-sonar` | Skip SonarQube (12.8) + Quality Gate — saves ~5 min + 1.5 GB RAM |
| `--skip-dast` | Skip ZAP scan (12.9) — use when cluster is not deployed |
| `--skip-build` | Skip Maven Build + Podman Build — use cached JARs/images |
| `--skip-install` | Abort instead of auto-installing a missing tool |
| `--nvd-key KEY` | NVD API key (avoids 30-min first-run download) |
| `--app-url URL` | DAST target (default: `http://localhost`) |
| `--repo DIR` | Repository root (default: current directory) |

### 13.4 Common run scenarios

```bash
# Quick pre-commit check — no build needed (~1-2 min)
# Runs: Gitleaks → Hadolint → Trivy config → Kubesec → kube-score → Checkstyle → Semgrep
./security-pipeline.sh --skip-sonar --skip-dast --skip-build

# After a code change — full check without slow steps (~15-20 min)
./security-pipeline.sh --skip-sonar --skip-dast --nvd-key $NVD_API_KEY

# DAST against running kind cluster
./scripts/kind-deploy.sh          # ensure cluster is up
./security-pipeline.sh --skip-sonar --app-url http://localhost

# Full pipeline (~30-40 min, requires ~1.5 GB free RAM for SonarQube)
./security-pipeline.sh --nvd-key $NVD_API_KEY
```

### 13.5 Where it fits in the v3 workflow

```
1. ./security-pipeline.sh --skip-dast --skip-build
   └─ Gitleaks + Hadolint + Trivy config + Kubesec + kube-score + Semgrep
      Fast feedback before building anything (~2 min)

2. ./security-pipeline.sh --skip-sonar --skip-dast --nvd-key $KEY
   └─ Full source + build + image scan

3. ./scripts/kind-deploy.sh
   └─ Deploy to kind cluster

4. ./security-pipeline.sh --skip-sonar --app-url http://localhost
   └─ DAST against the live cluster
```

### 13.6 Reports

Every run writes a timestamped directory under `/tmp/pipeline-reports/`:

```
/tmp/pipeline-reports/20260802-072802/
├── pipeline.log               ← combined log of all steps
├── gitleaks.json              ← secret findings (empty = clean)
├── hadolint.log
├── trivy-config.json          ← Dockerfile + K8s YAML misconfigurations
├── kubesec.json               ← per-manifest security scores
├── kube-score.txt             ← full kube-score CI output
├── kind-rendered.yaml         ← kustomize output used by kube-score
├── semgrep-java.json          ← Java SAST findings
├── semgrep-js.json            ← React/JS SAST findings
├── build.log
├── nvd.log
│   (HTML + JSON also at: */target/dependency-check-report.*)
├── lint.log
├── podman_build.log
├── trivy-image-*.json         ← per-image CVE findings
├── sonar-token.txt
├── zap-report.html            ← open in browser
└── zap-report.json
```

### 13.7 Terminal output

```
╔════════════════════════════════════════════════════════════╗
║    SECURITY & CODE QUALITY PIPELINE — v3 SUMMARY           ║
╠════════════════════════════════════════════════════════════╣
║  ✔  12.1    Gitleaks          Secret Scanning          2s  ║
║  ✔  12.2    Hadolint          Dockerfile Lint          1s  ║
║  ✔  12.3    Trivy Config      Dockerfiles + K8s YAML   2s  ║
║  ✔  12.4    Kubesec           K8s Manifest Scoring     4s  ║
║  ✔  12.5    kube-score        K8s Best-Practice        1s  ║
║  ✔  12.6a   Checkstyle        Java Code Style          5s  ║
║  ✔  12.6b   Semgrep           SAST                    10s  ║
║  ✔  12.6c   Maven Build       Compile & Package      145s  ║
║  ✔  12.6d   NVD Check         Dependency CVEs        240s  ║
║  ✔  12.6e   Lint              ESLint + SpotBugs       28s  ║
║  ✔  12.7a   Podman Build      Container Images       180s  ║
║  ✔  12.7b   Trivy Image       Image CVE Scan          35s  ║
║  ✔  12.8a   SonarQube         Quality Analysis        65s  ║
║  ✔  12.8b   Quality Gate      Merge/Deploy Gate        8s  ║
║  ✔  12.9    DAST              ZAP vs Kind Cluster     95s  ║
╠════════════════════════════════════════════════════════════╣
║  ALL CHECKS PASSED — safe to merge/deploy                  ║
║  Pass:15  Fail:0  Skip:0  Total:821s                       ║
╚════════════════════════════════════════════════════════════╝
```
