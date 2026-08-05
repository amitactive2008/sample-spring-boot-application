# Issue Tracker — v4 Deployment Guide (Helm + Envoy Gateway + HTTPS on kind)

Helm-driven deployment of the Issue Tracker on a local **kind** cluster. v4 replaces
the raw Kustomize manifests of v3 with a single Helm chart and upgrades the ingress
layer from nginx `Ingress` to **Envoy Gateway** + **Gateway API HTTPRoute** + **cert-manager**
TLS — giving you HTTPS on `sample-app.kind.local` with a self-signed certificate, HTTP→HTTPS redirect,
and `/api` prefix stripping, all declaratively configured.

Developer entry points:

- [Architecture](docs/ARCHITECTURE.md) — service boundaries and request flow.
- [Contributing](CONTRIBUTING.md) — local workflow and Git expectations.
- [AI contributor guide](AGENTS.md) — repository rules for coding agents.
- `./scripts/verify.sh all` — repeatable backend, frontend, Helm, shell, and Git checks.

---

## Table of Contents

1. [What Changed from v3](#1-what-changed-from-v3)
2. [Architecture](#2-architecture)
3. [Repository Layout](#3-repository-layout)
4. [Prerequisites](#4-prerequisites)
5. [Quick Deploy — One Command](#5-quick-deploy--one-command)
6. [Step-by-Step Manual Deploy](#6-step-by-step-manual-deploy)
7. [Helm Chart Reference](#7-helm-chart-reference)
8. [Envoy Gateway & Gateway API Explained](#8-envoy-gateway--gateway-api-explained)
9. [cert-manager & TLS Explained](#9-cert-manager--tls-explained)
10. [Verify the Deployment](#10-verify-the-deployment)
11. [Day-2 Operations](#11-day-2-operations)
12. [Tear Down](#12-tear-down)
13. [Security & Code Quality Pipeline](#13-security--code-quality-pipeline)
14. [Automated Verification](#14-automated-verification)

---

## 1. What Changed from v3

| Concern | v3 (Kustomize + nginx) | v4 (Helm + Envoy Gateway) |
|---|---|---|
| Templating | Kustomize base + overlays | Helm chart with `values.yaml` |
| Ingress controller | nginx Ingress Controller | **Envoy Gateway** (Kubernetes Gateway API) |
| Routing resource | `networking.k8s.io/v1 Ingress` | **`gateway.networking.k8s.io/v1 HTTPRoute`** |
| TLS | none (HTTP only) | **cert-manager** self-signed certificate (HTTPS) |
| HTTP→HTTPS | not configured | Automatic 301 redirect via HTTPRoute |
| Prefix stripping | nginx `rewrite-target` annotation | HTTPRoute `URLRewrite` filter |
| Cluster config | `kubernetes/environments/kind/kind-cluster.yaml` | `kind/kind-cluster.yaml` (maps host ports 80/443) |
| Release management | `kubectl apply -k` | `helm upgrade --install` |
| Dry-run / lint | `kubectl diff -k` | `helm lint` + `helm template` |
| Rollback | `kubectl apply` of previous commit | `helm rollback <release> <revision>` |
| Override values | Kustomize patches | `helm --set` flags or `-f values-override.yaml` |

---

## 2. Architecture

```
  Browser
    │
    │  https://sample-app.kind.local   (or HTTP → 301 → HTTPS)
    ▼
┌────────────────────────────────────────────────────────────────────────┐
│              kind single-node cluster  (kind-issue-app)                │
│                                                                        │
│  kind extraPortMappings:                                               │
│    host:80  → node:80   (HTTP listener → redirect)                    │
│    host:443 → node:443  (HTTPS listener → TLS termination)            │
│                                                                        │
│  ┌────────────────────────────────────────────────────────────────┐   │
│  │           Envoy Gateway Controller                              │   │
│  │           namespace: envoy-gateway-system                       │   │
│  │                                                                 │   │
│  │   Watches: GatewayClass "envoy-gateway"                        │   │
│  │   Provisions: Envoy proxy Deployment + Service per Gateway     │   │
│  └──────────────────────────┬──────────────────────────────────── ┘   │
│                             │ creates                                  │
│  ┌──────────────────────────▼──────────────────────────────────── ┐   │
│  │           Envoy Proxy (Deployment + Service)                    │   │
│  │           namespace: issue-app                                  │   │
│  │           hostPort: 80, 443  ← receives traffic from kind      │   │
│  └──────┬───────────────────────────────────────┬─────────────────┘   │
│         │ HTTP listener (:80)                   │ HTTPS listener (:443)│
│         │                                       │ TLS: cert-manager    │
│         ▼                                       ▼ self-signed cert     │
│  ┌──────────────────┐               ┌───────────────────────────────┐ │
│  │ HTTPRoute:       │               │ HTTPRoute:                    │ │
│  │ http-redirect    │               │ https-routes                  │ │
│  │                  │               │                               │ │
│  │ ALL → 301 HTTPS  │               │ /api/* → api-gateway :80      │ │
│  └──────────────────┘               │   (strips /api via URLRewrite)│ │
│                                     │ /    → frontend-service :80   │ │
│                                     └──────┬──────────────┬─────────┘ │
│                                            │              │            │
│                                     ┌──────▼─────┐  ┌────▼─────────┐ │
│                                     │api-gateway │  │frontend-svc  │ │
│                                     │ :80→:8096  │  │ :80→:3000    │ │
│                                     └──────┬─────┘  └──────────────┘ │
│                                            │                          │
│                                  /auth/**  │  /issues/**              │
│                                     ┌──────┴──────────┐              │
│                                     │                 │               │
│                              ┌──────▼────┐    ┌──────▼──────┐        │
│                              │auth-svc   │    │issue-svc    │        │
│                              │:80→:8097  │    │:80→:8098    │        │
│                              └──────┬────┘    └──────┬──────┘        │
│                                     └────────┬────────┘               │
│                                              │                        │
│                                     ┌────────▼────────┐              │
│                                     │   MySQL :3306   │              │
│                                     │   PVC: mysql-pvc│              │
│                                     └─────────────────┘              │
│                                                                        │
│  cert-manager (namespace: cert-manager)                               │
│    ClusterIssuer: issue-tracker-selfsigned-issuer                     │
│    Certificate → Secret: issue-tracker-tls-secret                     │
└────────────────────────────────────────────────────────────────────────┘
```

**Request flow (HTTPS):**
```
Browser  GET https://sample-app.kind.local/api/auth/login
  → kind extraPortMapping :443 → node:443
  → Envoy proxy (hostPort 443)
  → TLS terminated (cert-manager self-signed cert)
  → HTTPRoute https-routes, matches /api/*
  → URLRewrite: strip /api  →  /auth/login
  → api-gateway Service (:80)  →  api-gateway Pod (:8096)
  → Spring Cloud Gateway route: Path=/auth/**
  → auth-service Service (:80)  →  auth-service Pod (:8097)
```

---

## 3. Repository Layout

```text
AGENTS.md                           # AI contributor rules
CONTRIBUTING.md                     # human contributor workflow
docs/ARCHITECTURE.md                # service and deployment architecture

api-gateway/                        # reactive routing and JWT validation
auth-service/                       # authentication and user administration
issue-service/                      # issue workflows and history
frontend-service/                   # React single-page application

helm/
└── issue-tracker/
    ├── Chart.yaml                # chart metadata
    ├── values.yaml               # defaults (kind dev)
    ├── values-prod.yaml          # production overrides (AWS EKS + ECR)
    └── templates/
        ├── _helpers.tpl          # shared template helpers
        ├── namespace.yaml        # Namespace: issue-app
        ├── serviceaccount.yaml   # ServiceAccount: issue-app-sa
        ├── secrets.yaml          # K8s Secrets (jwt, db creds, admin seed)
        ├── configmaps.yaml       # ConfigMaps (JDBC URL, mail flag)
        ├── mysql.yaml            # MySQL Deployment + Service + PVC (local only)
        ├── auth-service.yaml     # Deployment + Service
        ├── issue-service.yaml    # Deployment + Service + PVC
        ├── api-gateway.yaml      # Deployment + Service
        ├── frontend-service.yaml # Deployment + Service
        ├── ingress.yaml          # Legacy nginx Ingress (ingress.enabled=true)
        ├── gateway.yaml          # NEW: EnvoyProxy + Gateway resources
        ├── httproute.yaml        # NEW: HTTP redirect + HTTPS routing HTTPRoutes
        └── certmanager.yaml      # NEW: ClusterIssuer + Certificate

kind/
└── kind-cluster.yaml             # kind cluster config (host ports 80/443)

scripts/
├── helm-deploy.sh                # Podman + Kind + Helm deployment
└── verify.sh                     # repeatable contributor checks
```

---

## 4. Prerequisites

### 4.1 kind, kubectl, Helm

```bash
# macOS
brew install kind kubectl helm

kind    --version   # kind v0.23.x
kubectl version --client
helm    version     # v3.x.x
```

### 4.2 Podman

```bash
# macOS
brew install podman
podman machine init             # first installation only
podman machine start

podman info                    # must succeed
```

Podman Desktop is optional; the deployment script uses the Podman CLI and its
machine. Docker Desktop is not required. The script sets
`KIND_EXPERIMENTAL_PROVIDER=podman` automatically.

### 4.3 Local hostname

Add the development hostname once on macOS:

```bash
echo "127.0.0.1 sample-app.kind.local" | sudo tee -a /etc/hosts
```

Confirm it resolves before opening the application:

```bash
dscacheutil -q host -a name sample-app.kind.local
```

### 4.4 System requirements

| Resource | Minimum | Recommended |
|---|---|---|
| CPU | 2 cores | 4 cores |
| RAM | 6 GB free | 12 GB free |
| Disk | 10 GB free | 20 GB free |

---

## 5. Quick Deploy — One Command

```bash
git clone -b v4-kind-with-helm \
  https://github.com/amitactive2008/sample-spring-boot-application.git
cd sample-spring-boot-application

chmod +x scripts/helm-deploy.sh
./scripts/helm-deploy.sh
```

What the script does:

| Step | Action |
|---|---|
| 1 | Creates kind cluster `issue-app` from `kind/kind-cluster.yaml` |
| 2 | Installs Envoy Gateway and its compatible Gateway API CRDs via Helm |
| 3 | Waits for the Envoy Gateway controller in `envoy-gateway-system` |
| 4 | Installs cert-manager via Helm in `cert-manager`; waits for webhook |
| 5 | Builds all 4 container images with Podman |
| 6 | Saves the Podman images and loads their archives into kind |
| 7 | `helm upgrade --install` — deploys all app resources + Gateway + Certificate |
| 8 | Waits for cert-manager to issue the TLS certificate |
| 9 | Verifies the direct Kind HTTP/HTTPS mappings and API health route |

When complete:

```
════════════════════════════════════════════════════════════
  Issue Tracker — running on kind with HTTPS!
════════════════════════════════════════════════════════════

  Frontend  →  https://sample-app.kind.local
  API       →  https://sample-app.kind.local/api
  HTTP      →  http://sample-app.kind.local  (redirects → HTTPS)
════════════════════════════════════════════════════════════
```

---

## 6. Step-by-Step Manual Deploy

### 6.1 Create the kind cluster

```bash
export KIND_EXPERIMENTAL_PROVIDER=podman

kind create cluster \
  --name issue-app \
  --config kind/kind-cluster.yaml

kubectl config current-context   # kind-issue-app
kubectl get nodes                # STATUS: Ready
```

### 6.2 Gateway API CRD ownership

The pinned Envoy Gateway chart includes the compatible Gateway API CRDs
(`GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`, etc.). Do not install a
second CRD bundle with `kubectl`; doing so creates Helm field-ownership conflicts.
The application chart then creates the `envoy-gateway` GatewayClass that selects
the installed controller.

### 6.3 Install Envoy Gateway

```bash
helm upgrade --install envoy-gateway \
  oci://docker.io/envoyproxy/gateway-helm \
  --version v1.2.1 \
  --namespace envoy-gateway-system \
  --create-namespace \
  --wait --timeout 3m

kubectl get pods -n envoy-gateway-system   # STATUS: Running
```

Verify the `GatewayClass` is accepted:

```bash
kubectl get gatewayclass envoy-gateway
# NAME            CONTROLLER                                      ACCEPTED
# envoy-gateway   gateway.envoyproxy.io/gatewayclass-controller  True
```

### 6.4 Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io --force-update

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.15.3 \
  --set crds.enabled=true \
  --wait --timeout 3m

# Wait for the webhook (important — the Helm chart may return before it's ready)
kubectl wait deployment/cert-manager-webhook \
  --namespace cert-manager \
  --for=condition=Available \
  --timeout=60s

kubectl get pods -n cert-manager   # all 3 pods Running
```

### 6.5 Build and load images

```bash
export KIND_EXPERIMENTAL_PROVIDER=podman

podman build -t localhost/auth-service:local     ./auth-service
podman build -t localhost/issue-service:local    ./issue-service
podman build -t localhost/api-gateway:local      ./api-gateway
podman build -t localhost/frontend-service:local ./frontend-service

podman save localhost/auth-service:local \
  | kind load image-archive /dev/stdin --name issue-app
podman save localhost/issue-service:local \
  | kind load image-archive /dev/stdin --name issue-app
podman save localhost/api-gateway:local \
  | kind load image-archive /dev/stdin --name issue-app
podman save localhost/frontend-service:local \
  | kind load image-archive /dev/stdin --name issue-app
```

### 6.6 Deploy via Helm

```bash
helm upgrade --install issue-tracker helm/issue-tracker \
  --namespace issue-app \
  --create-namespace \
  --wait --timeout 8m \
  --atomic

helm status issue-tracker -n issue-app
```

### 6.7 Wait for the TLS certificate

cert-manager will detect the `Certificate` resource created by Helm and issue the
self-signed certificate into the `issue-tracker-tls-secret` Secret.

```bash
# Watch certificate status
kubectl get certificate -n issue-app -w
# NAME                          READY   SECRET                     AGE
# issue-tracker-tls-cert        True    issue-tracker-tls-secret   30s

kubectl describe certificate -n issue-app issue-tracker-tls-cert
```

### 6.8 Verify the direct Kind port mappings

Kind maps macOS ports `80` and `443` to the Envoy listeners in the control-plane
container. No `kubectl port-forward` process is required:

```bash
./scripts/helm-deploy.sh check
curl -I http://sample-app.kind.local/     # 301 to HTTPS
curl -k https://sample-app.kind.local/    # frontend HTML
```

### 6.9 Trust the self-signed certificate (optional)

The cert-manager self-signed certificate will show a browser warning. To suppress it,
extract the CA certificate and add it to your OS trust store:

```bash
# Extract the CA cert from the TLS Secret
kubectl get secret -n issue-app issue-tracker-tls-secret \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/issue-tracker-ca.crt

# macOS — add to keychain and trust
sudo security add-trusted-cert \
  -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  /tmp/issue-tracker-ca.crt

# Linux — add to system trust store
sudo cp /tmp/issue-tracker-ca.crt /usr/local/share/ca-certificates/issue-tracker.crt
sudo update-ca-certificates

# curl — skip verification for testing
curl -k https://sample-app.kind.local/
```

### 6.10 Open the application

```
https://sample-app.kind.local
```

Login: `admin@example.com` / `Admin1234!`

---

## 7. Helm Chart Reference

### 7.1 Key values

| Key | Default | Description |
|---|---|---|
| `global.imagePullPolicy` | `Never` | `Never` for kind (local images); `IfNotPresent` for cloud |
| `jwt.secret` | `local-kind-jwt-secret-key-32bytes!!` | HMAC-SHA256 key — **change in production** |
| `admin.email` | `admin@example.com` | Seeded admin account |
| `admin.password` | `Admin1234!` | Seeded admin password |
| `db.name` | `game_db` | MySQL database name |
| `db.username` | `game_admin` | MySQL user |
| `db.password` | `devpassword123` | MySQL password |
| `mysql.enabled` | `true` | `false` in prod (use RDS) |
| `gatewayAPI.enabled` | `true` | `false` to fall back to nginx Ingress |
| `gatewayAPI.hostname` | `sample-app.kind.local` | DNS name for Gateway listeners + Certificate |
| `gatewayAPI.httpRedirect` | `true` | Redirect HTTP → HTTPS |
| `gatewayAPI.apiPrefix` | `/api` | Path prefix stripped before forwarding to gateway |
| `tls.enabled` | `true` | Create cert-manager Certificate |
| `tls.issuerType` | `selfsigned` | `selfsigned` / `letsencrypt-staging` / `letsencrypt` |
| `tls.secretName` | `issue-tracker-tls-secret` | Secret name for TLS keypair |
| `ingress.enabled` | `false` | Legacy nginx Ingress (mutually exclusive with gatewayAPI) |

### 7.2 Common overrides

Override at deploy time with `--set`:

```bash
# Change JWT secret
helm upgrade issue-tracker helm/issue-tracker -n issue-app \
  --set jwt.secret="MyProductionJWTSecretLongEnough32!"

# Use a different custom hostname and update /etc/hosts to match
helm upgrade issue-tracker helm/issue-tracker -n issue-app \
  --set gatewayAPI.hostname="issue-tracker.local" \
  --set apiGateway.cors.allowedOrigin="https://issue-tracker.local"

# Switch to letsencrypt-staging (requires real DNS + public IP)
helm upgrade issue-tracker helm/issue-tracker -n issue-app \
  --set tls.issuerType="letsencrypt-staging" \
  --set tls.acmeEmail="me@example.com" \
  --set gatewayAPI.hostname="yourdomain.com"
```

### 7.3 Helm subcommands

```bash
# Lint the chart (no cluster needed)
./scripts/helm-deploy.sh lint

# Dry-run render — see what would be applied
helm template issue-tracker helm/issue-tracker --namespace issue-app

# Show current release status
helm status issue-tracker -n issue-app

# Show release history
helm history issue-tracker -n issue-app

# Roll back to previous revision
helm rollback issue-tracker 1 -n issue-app

# Uninstall (keeps PVCs — data preserved)
helm uninstall issue-tracker -n issue-app

# Uninstall + delete PVCs (full data wipe)
helm uninstall issue-tracker -n issue-app
kubectl delete pvc -n issue-app --all
```

---

## 8. Envoy Gateway & Gateway API Explained

### 8.1 Why Gateway API instead of Ingress?

| Feature | nginx `Ingress` | Gateway API `HTTPRoute` |
|---|---|---|
| Standard | vendor-specific annotations | Kubernetes SIG-Network standard |
| Expressiveness | annotation hacks | first-class request matching, redirect, rewrite filters |
| Role separation | single resource | `GatewayClass` (infra), `Gateway` (ops), `HTTPRoute` (dev) |
| TLS | Secret reference | `certificateRefs` with cert-manager integration |
| HTTP→HTTPS redirect | annotation | `RequestRedirect` filter in HTTPRoute |
| Header modification | annotation | `RequestHeaderModifier` filter |
| Traffic weighting | not supported | `weight` field on `backendRefs` |

### 8.2 Resource hierarchy

```
GatewayClass "envoy-gateway"          (cluster-scoped, managed by this Helm chart)
    └── Gateway "issue-tracker-gateway"  (namespace-scoped, managed by Helm chart)
            ├── Listener: http  (:80)
            │       └── HTTPRoute "...-http-redirect"   → 301 to HTTPS
            └── Listener: https (:443, TLS terminated)
                    └── HTTPRoute "...-https-routes"
                            ├── /api/* → api-gateway (URLRewrite strips /api)
                            └── /     → frontend-service
```

### 8.3 EnvoyProxy custom resource

The `EnvoyProxy` resource in `gateway.yaml` configures how Envoy Gateway provisions the
Envoy proxy for this release. For kind, it sets:

- a no-surge deployment strategy because a single node cannot reserve the same
  fixed host ports for old and new Envoy pods at once;
- host ports `80` and `443` on Envoy's generated listener ports `10080` and `10443`.

- `envoyService.type: NodePort` — exposes Envoy on the kind node's network
- `envoyDeployment.patch` — adds `hostPort: 80` and `hostPort: 443` to the Envoy
  container, so kind's `extraPortMappings` (host:80→node:80, host:443→node:443)
  route traffic directly into the Envoy pods

### 8.4 URLRewrite filter

The `/api` prefix is stripped by an `HTTPRoute` `URLRewrite` filter:

```yaml
filters:
  - type: URLRewrite
    urlRewrite:
      path:
        type: ReplacePrefixMatch
        replacePrefixMatch: "/"
```

`/api/auth/login` → `URLRewrite` → `/auth/login` → api-gateway Spring route matches
`Path=/auth/**` → forwards to auth-service.

---

## 9. cert-manager & TLS Explained

### 9.1 How cert-manager works

```
Helm deploys Certificate resource
       │
       ▼
cert-manager detects Certificate
       │
       ▼
cert-manager creates CertificateRequest
       │
       ▼
ClusterIssuer "issue-tracker-selfsigned-issuer" signs it
       │
       ▼
cert-manager writes tls.crt + tls.key into Secret "issue-tracker-tls-secret"
       │
       ▼
Envoy Gateway reads the Secret for the HTTPS listener's TLS termination
       │
       ▼
Envoy proxy terminates TLS on port 443
```

### 9.2 Issuer types

| `tls.issuerType` | CA | Use case |
|---|---|---|
| `selfsigned` | In-cluster generated key | Local dev — no DNS required |
| `letsencrypt-staging` | Let's Encrypt staging CA | Test ACME flow — not browser-trusted |
| `letsencrypt` | Let's Encrypt production CA | Production — publicly trusted, requires public DNS |

### 9.3 Certificate lifecycle

- **Duration:** 90 days (`tls.duration: 2160h`)
- **Auto-renewal:** 15 days before expiry (`tls.renewBefore: 360h`)
- cert-manager automatically renews the certificate and updates the Secret; Envoy Gateway
  hot-reloads the new certificate without downtime

### 9.4 View certificate details

```bash
# Current certificate status
kubectl get certificate -n issue-app

# Full certificate details
kubectl describe certificate -n issue-app issue-tracker-tls-cert

# View the actual TLS cert
kubectl get secret -n issue-app issue-tracker-tls-secret \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout

# Check expiry
kubectl get secret -n issue-app issue-tracker-tls-secret \
  -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -dates
```

---

## 10. Verify the Deployment

### 10.1 Check all resources

```bash
# Pods
kubectl get pods -n issue-app

# Gateway API resources
kubectl get gatewayclass,gateway,httproute -n issue-app

# cert-manager certificate
kubectl get certificate,certificaterequest -n issue-app

# Envoy proxy Service (dynamically named)
kubectl get svc -n issue-app \
  --selector="gateway.envoyproxy.io/owning-gateway-name=issue-tracker-gateway"
```

### 10.2 API smoke tests

```bash
# Login (HTTPS — -k skips cert verification for self-signed)
TOKEN=$(curl -sk -X POST https://sample-app.kind.local/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@example.com","password":"Admin1234!"}' \
  | jq -r '.accessToken')

echo "Token: ${TOKEN:0:50}..."

# HTTP → HTTPS redirect
curl -v http://sample-app.kind.local/api/auth/login 2>&1 | grep "< HTTP\|< Location"
# expected: HTTP/1.1 301 and Location: https://sample-app.kind.local/api/auth/login

# Create an issue
curl -sk -X POST https://sample-app.kind.local/api/issues \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title":"HTTPS smoke test","priority":"HIGH","severity":"MEDIUM"}'

# List issues
curl -sk "https://sample-app.kind.local/api/issues" \
  -H "Authorization: Bearer $TOKEN" | jq '.content[].title'
```

### 10.3 Open UI

```
https://sample-app.kind.local
```

Accept the self-signed certificate warning, or import the CA cert (Section 6.9).

---

## 11. Day-2 Operations

### Rebuild and redeploy a single service

```bash
podman build -t localhost/auth-service:local ./auth-service
podman save localhost/auth-service:local \
  | kind load image-archive /dev/stdin --name issue-app
kubectl rollout restart -n issue-app deploy/auth-service
kubectl rollout status  -n issue-app deploy/auth-service
```

### Upgrade the full release

```bash
./scripts/helm-deploy.sh upgrade
# This rebuilds all images, reloads into kind, and runs helm upgrade
```

### Override a value without rebuilding

```bash
helm upgrade issue-tracker helm/issue-tracker -n issue-app \
  --reuse-values \
  --set apiGateway.cors.allowedOrigin="https://issue-tracker.local"
```

### Verify the gateway after a terminal restart

```bash
./scripts/helm-deploy.sh check
```

### View resource consumption

```bash
kubectl top pods -n issue-app
kubectl top nodes
```

### Access MySQL directly

```bash
MYSQL_POD=$(kubectl get pod -n issue-app -l app=issue-tracker-mysql -o name | head -1)
kubectl exec -it -n issue-app "$MYSQL_POD" -- \
  mysql -u game_admin -pdevpassword123 game_db
```

### Inspect HTTPRoute status

```bash
kubectl describe httproute -n issue-app issue-tracker-gateway-https-routes
# Look for: "Accepted: True" and "ResolvedRefs: True" conditions
```

---

## 12. Tear Down

```bash
./scripts/helm-deploy.sh teardown
# Deletes the kind cluster and all workloads in it
```

Manual:

```bash
# Uninstall Helm release (removes app resources)
helm uninstall issue-tracker -n issue-app

# Uninstall cert-manager and Envoy Gateway
helm uninstall cert-manager -n cert-manager
helm uninstall envoy-gateway -n envoy-gateway-system

# Delete the cluster
kind delete cluster --name issue-app
```

---

## 13. Security & Code Quality Pipeline

v4 inherits the **entire security pipeline from v3** and adds three layers specific to
Helm and the new infrastructure components:

- **`helm lint`** — Helm chart syntax and best-practice validation
- **Helm template + kubesec / kube-score** — render the chart, then scan rendered manifests
- **Trivy config extended** — scans the `helm/` directory for Helm chart misconfigurations

### Run `security-pipeline.sh`

Run the pipeline from the repository root. The script checks source code, the Helm
chart and rendered Kubernetes manifests, Java and JavaScript dependencies,
container images, Sonar quality gates, and the deployed application.

```bash
# Confirm the script and its options
./security-pipeline.sh --help

# Configure credentials in the current shell; never add them to a tracked file
export SONAR_TOKEN="replace-with-your-sonarcloud-token"
export NVD_API_KEY="replace-with-your-nvd-api-key"

# SonarCloud identity for this repository
export SONAR_MODE=cloud
export SONAR_HOST_URL=https://sonarcloud.io
export SONAR_ORGANIZATION=amitactive2008
export SONAR_PROJECT_KEY_PREFIX=amitactive2008_sample-spring-boot-application

# Full scan, including SonarCloud and DAST
./security-pipeline.sh
```

The full scan can take a long time on its first run because Maven, Trivy, Semgrep,
container images, and the NVD vulnerability database may need to be downloaded.
Each service has a `.dockerignore` so generated Maven output, `node_modules`, React
build output, scanner state, and local environment files are not copied into the
Podman build context. Trivy uses the Podman machine socket when available, avoiding
large temporary image archives; it falls back to a temporary archive on other
Podman installations.
Run the Kind deployment before enabling DAST:

```bash
./scripts/helm-deploy.sh check
```

Common scan modes:

```bash
# Source and configuration checks only; no NVD, build, Sonar, or DAST
./security-pipeline.sh --skip-nvd --skip-build --skip-sonar --skip-dast

# Build, dependency, lint, and image checks without SonarCloud or DAST
./security-pipeline.sh --skip-sonar --skip-dast

# Reuse cached images/classes but still incrementally update NVD and scan dependencies
./security-pipeline.sh --skip-build --skip-sonar --skip-dast

# CI or pre-provisioned workstation: fail instead of installing missing tools
./security-pipeline.sh --skip-install --skip-sonar --skip-dast
```

Supported options:

| Option | Effect |
|---|---|
| `--skip-nvd` | Skip the NVD update, Java Dependency-Check scans, and npm audit |
| `--skip-sonar` | Skip Sonar analysis and its quality gate |
| `--skip-dast` | Skip the OWASP ZAP scan |
| `--skip-build` | Skip Maven builds, lint, Podman builds, and image scans; NVD still runs |
| `--skip-install` | Do not install missing command-line tools |
| `--nvd-key KEY` | Supply an NVD API key; prefer the `NVD_API_KEY` environment variable so it is not stored in shell history |
| `--nvd-data-dir DIR` | Override the persistent Dependency-Check database directory |
| `--sonar-mode MODE` | Select `cloud`, `local`, or `external` Sonar operation |
| `--sonar-host URL` | Override the Sonar server URL |
| `--sonar-org KEY` | Set the SonarCloud organization key |
| `--sonar-project-prefix KEY` | Set the prefix used for the four per-service project keys |
| `--app-url URL` | Set the deployed application URL used by DAST |
| `--repo DIR` | Scan a repository directory other than the current directory |

The NVD step uses this persistent local database:

```text
.security-cache/dependency-check/
```

It performs one incremental database update, then scans `auth-service`,
`issue-service`, and `api-gateway` with network updates disabled. The frontend npm
audit uses the same pipeline step but writes its own JSON report.

Each run writes logs and machine-readable reports to:

```text
security-reports/YYYYMMDD-HHMMSS/
├── nvd/
│   ├── auth-service/
│   ├── issue-service/
│   ├── api-gateway/
│   └── npm-audit.json
├── helm-rendered.yaml
├── kubesec.json
├── kube-score.txt
├── trivy-config.json
├── trivy-image-*.json
├── semgrep-*.json
└── pipeline.log
```

SonarCloud uses four project keys derived from the configured prefix:

```text
amitactive2008_sample-spring-boot-application_auth-service
amitactive2008_sample-spring-boot-application_issue-service
amitactive2008_sample-spring-boot-application_api-gateway
amitactive2008_sample-spring-boot-application_frontend-service
```

The Sonar token stays in the process environment and is not written to a report.
The token must be authorized to analyze these projects in the
`amitactive2008` organization.
`SONAR_MODE=local` targets an already-running SonarQube server; the pipeline does
not create a SonarQube container or generate administrator credentials.

Kubesec runs locally in the official `kubesec/kubesec:v2` container. On Apple
Silicon, Podman uses amd64 emulation because that image does not publish an arm64
variant. Rendered Kubernetes manifests are not uploaded to the public Kubesec API.

Operational notes:

- The default DAST target is `https://sample-app.kind.local`; deploy the Kind
  environment and add the documented `/etc/hosts` entry first.
- The development certificate is self-signed. The pipeline accepts it only for
  the local DAST preflight and configures the ZAP container for the development
  endpoint.
- A summary with skipped checks is a partial scan, even if the remaining checks
  pass; do not treat that result as a complete release approval.

Never commit `NVD_API_KEY`, `SONAR_TOKEN`, application credentials, generated
reports, or scanner caches. `.gitignore` excludes `.security-cache/`,
`security-reports/`, and `.scannerwork/` directories.

```
Developer push / Pull Request
          │
          ▼
  ┌───────────────┐
  │  1. Gitleaks  │  ← secrets in git? jwt.secret in values.yaml committed?
  └───────┬───────┘
          ▼
  ┌─────────────────┐
  │  2. Hadolint    │  ← all 4 Dockerfiles linted
  └───────┬─────────┘
          ▼
  ┌──────────────────────┐
  │  3. helm lint        │  ← NEW: Helm chart syntax, template rendering, schema
  └──────────┬───────────┘
          ▼
  ┌──────────────────────────────┐
  │  4. Trivy config             │  ← Dockerfiles + K8s YAML + Helm chart templates
  │  (helm/ + Dockerfiles)       │
  └──────────────────┬───────────┘
          ▼
  ┌────────────────────────────────────┐
  │  5. Kubesec                        │  ← rendered Helm manifests risk scoring
  │  (helm template | kubesec scan)    │
  └──────────────────┬─────────────────┘
          ▼
  ┌────────────────────────────────────┐
  │  6. kube-score                     │  ← rendered manifests best-practice check
  │  (helm template | kube-score score)│
  └──────────────────┬─────────────────┘
          ▼
  ┌────────────────┐
  │  7. Checkstyle │  ← Java code style
  └───────┬────────┘
          ▼
  ┌──────────────────────────────┐
  │  8. Semgrep                  │  ← SAST: Java + JS + Dockerfile + K8s patterns
  └──────────────────┬───────────┘
          ▼
  ┌──────────────────────────────┐
  │  9. Maven Build -DskipTests  │  ← compile + package all 3 services
  └──────────────────┬───────────┘
          ▼
  ┌─────────────────────┐
  │  10. NVD Check      │  ← OWASP Dep-Check (JARs) + npm audit
  └──────────┬──────────┘
          ▼
  ┌──────────────┐
  │  11. Lint    │  ← ESLint + SpotBugs
  └──────┬───────┘
          ▼
  ┌─────────────────────┐
  │  12. Podman build   │  ← build all 4 images
  └──────────┬──────────┘
          ▼
  ┌──────────────────┐
  │  13. Trivy image │  ← OS + lib CVEs + secrets in layers (all 4 images)
  └──────┬───────────┘
          ▼
  ┌─────────────┐
  │ 14. Sonar   │  ← deep quality + security analysis
  └──────┬──────┘
          ▼
  ┌────────────────┐
  │ 15. Quality    │  ← pass/fail threshold — blocks merge
  │     Gate       │
  └──────┬─────────┘
          │
       MERGE
          │
     helm upgrade → kind staging cluster
          │
          ▼
  ┌──────────────────┐
  │  16. DAST Audit  │  ← OWASP ZAP against https://sample-app.kind.local
  └──────────────────┘
```

---

### 13.1 Gitleaks — Secret Scanning

Same as v3, with one new risk: `values.yaml` contains `jwt.secret`, `db.password`,
`admin.password`, and `mysql.rootPassword`. Any of these being a real production
credential and accidentally committed is a critical leak.

```bash
gitleaks detect --source . --verbose
```

`.gitleaks.toml` suppressions for known dummy dev values:

```toml
[allowlist]
description = "Suppress kind dev dummy credentials in values.yaml"
regexes = [
  "local-kind-jwt-secret-key-32bytes!!",
  "devpassword123",
  "rootpassword",
  "Admin1234!",
  "disabled"
]
```

**Rule:** `values.yaml` must only contain local dev dummy values. All production secrets
pass via `--set` flags from CI secrets or a Vault integration — never from files committed
to git.

---

### 13.2 Hadolint — Dockerfile Linting

Unchanged from v3. Lint all four Dockerfiles before building images:

```bash
find . -name "Dockerfile" | xargs hadolint --failure-threshold warning
```

---

### 13.3 `helm lint` — Helm Chart Validation

**What it is:**
`helm lint` runs a set of checks against the Helm chart:
- YAML syntax validity in all template files
- `values.yaml` schema conformance
- Template rendering errors (e.g., referencing undefined values)
- Chart metadata validation (`Chart.yaml`)

It does NOT require a cluster — it runs entirely locally.

**SDLC value:**
A broken Helm chart fails silently during `helm template` and loudly during `helm upgrade`.
Running `helm lint` in CI catches template errors, missing required values, and YAML
formatting issues at pull-request time — before any cluster interaction.

**How to apply:**

```bash
# Lint with default values
helm lint helm/issue-tracker

# Lint with a specific values file
helm lint helm/issue-tracker -f helm/issue-tracker/values-prod.yaml \
  --set jwt.secret="dummy32charsforlinttesting!!!!!" \
  --set db.host="rds.example.com"

# Lint and render templates (catches runtime template errors)
helm template issue-tracker helm/issue-tracker \
  --namespace issue-app \
  --debug \
  > /dev/null
```

In the deploy script (`./scripts/helm-deploy.sh lint`), `helm lint` runs first, followed
by kubesec and kube-score on the rendered output.

**In GitHub Actions:**

```yaml
- name: Helm lint
  run: |
    helm lint helm/issue-tracker
    helm template issue-tracker helm/issue-tracker \
      --namespace issue-app > /dev/null
```

---

### 13.4 Trivy Config — Extended to Helm Charts

In v4, `trivy config` scans three target types:
1. Dockerfiles — `DS*` rules (same as v3)
2. Kubernetes YAML — `KSV*` rules (same as v3, for rendered templates)
3. **Helm charts** — `HELM*` rules (new in v4)

```bash
# Scan the Helm chart directory directly
trivy config helm/issue-tracker

# Scan with custom values (renders templates before scanning)
trivy config \
  --helm-values helm/issue-tracker/values.yaml \
  helm/issue-tracker

# Scan everything — Dockerfiles + Helm templates + raw K8s YAML
trivy config \
  --exit-code 1 \
  --severity HIGH,CRITICAL \
  --format sarif \
  --output trivy-config.sarif \
  .
```

**Helm-specific rules Trivy will flag:**

| Rule | Severity | Finding | Fix |
|---|---|---|---|
| `KSV001` | HIGH | No `allowPrivilegeEscalation: false` in container securityContext | Add to all Deployment templates |
| `KSV014` | LOW | `readOnlyRootFilesystem` not set | Add + `emptyDir` for `/tmp` |
| `KSV020` | LOW | `runAsNonRoot` not set | Add `runAsNonRoot: true` to pod securityContext |
| `KSV030` | LOW | No seccomp profile | Add `seccompProfile.type: RuntimeDefault` |
| `HELM001` | LOW | `values.yaml` contains hardcoded passwords | Move to `--set` / secrets management |

---

### 13.5 Kubesec — Rendered Manifest Security Scoring

Render the Helm chart and pipe the output to kubesec:

```bash
# Score all rendered manifests
helm template issue-tracker helm/issue-tracker \
  --namespace issue-app \
  | kubesec scan /dev/stdin

# Score only Deployments (filter with grep)
helm template issue-tracker helm/issue-tracker \
  --namespace issue-app \
  | kubectl-neat \
  | grep -A 200 "kind: Deployment" \
  | kubesec scan /dev/stdin
```

Fail the pipeline if any manifest scores below 0:

```bash
SCORE=$(helm template issue-tracker helm/issue-tracker --namespace issue-app \
  | kubesec scan /dev/stdin | jq '[.[].score] | min')
echo "Lowest kubesec score: $SCORE"
[ "$SCORE" -ge 0 ] || exit 1
```

In the deploy script (`./scripts/helm-deploy.sh lint`) kubesec runs automatically if
installed.

---

### 13.6 kube-score — Helm Rendered Manifest Analysis

Render and pipe to kube-score:

```bash
helm template issue-tracker helm/issue-tracker \
  --namespace issue-app \
  | kube-score score -

# Fail on any CRITICAL finding
helm template issue-tracker helm/issue-tracker \
  --namespace issue-app \
  | kube-score score --exit-one-on-error -
```

**What kube-score will flag in the rendered v4 manifests:**

| Check | Severity | Finding |
|---|---|---|
| `container-security-context` | CRITICAL | Missing `allowPrivilegeEscalation` + `readOnlyRootFilesystem` |
| `pod-probes` | WARNING | auth-service and issue-service missing liveness/readiness probes |
| `network-policy` | WARNING | No `NetworkPolicy` resources |
| `pod-disruption-budget` | WARNING | No PodDisruptionBudget for stateful services |

These are the same as v3 — the recommended fixes (Spring Actuator probes, securityContext)
apply identically to the Helm templates.

---

### 13.7–13.11 Checkstyle, Semgrep, Maven Build, NVD Check, Lint

Unchanged from v3. See v3 README Section 12.6 for full configuration.

```bash
# Semgrep — add p/kubernetes for K8s/Helm YAML security patterns
semgrep --config p/spring-security --config p/java \
        --config p/javascript --config p/react \
        --config p/dockerfile --config p/kubernetes \
        --error .
```

---

### 13.12–13.13 Podman Build and Trivy Image Scan

Unchanged from v3. Build and scan all four images before loading into kind:

```bash
for IMAGE in auth-service issue-service api-gateway frontend-service; do
  trivy image \
    --exit-code 1 \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    --scanners vuln,secret \
    --no-progress \
    "${IMAGE}:local"
done
```

See v2 README Section 10.9 for full flags, output formats, caching, and secret scanning.

---

### 13.14–13.16 SonarCloud, Quality Gate, DAST

DAST runs against `https://sample-app.kind.local`, the Envoy Gateway HTTPS
endpoint. The pipeline discovers the Kind node address, attaches ZAP to the Kind
network, maps the hostname, and accepts only the local self-signed certificate:

```bash
# Ensure the cluster and direct gateway mappings are healthy
./scripts/helm-deploy.sh check

# Run only the deployed-app scan while skipping the expensive analysis phases
./security-pipeline.sh --skip-nvd --skip-sonar --skip-build
```

---

### Security Pipeline — Quick Reference (v4)

| # | Tool | Stage | Scope | Blocks? |
|---|---|---|---|---|
| 1 | **Gitleaks** | Pre-commit / CI | Git history; `values.yaml` credential leak | Yes |
| 2 | **Hadolint** | CI — pre-build | 4 Dockerfiles | Yes |
| 3 | **`helm lint`** | CI — chart validation | Helm chart syntax + template rendering | Yes |
| 4 | **Trivy config** | CI — pre-build | Dockerfiles + **Helm chart** (`HELM*` + `KSV*` rules) | Yes |
| 5 | **Kubesec** | CI — rendered manifests | Helm-rendered K8s manifests risk score | Yes (score < 0) |
| 6 | **kube-score** | CI — rendered manifests | Helm-rendered manifests best-practice | Yes (CRITICAL) |
| 7 | **Checkstyle** | CI — validate | Java source style | Yes |
| 8 | **Semgrep** | CI — SAST | Java + JS/React | Yes (ERROR) |
| 9 | **Maven Build** | CI — compile | 3 Spring Boot services | Yes |
| 10 | **NVD Check** | CI — SCA | JARs + npm packages | Yes (CVSS ≥ 7 / npm high) |
| 11 | **Lint** | CI | ESLint (React) + SpotBugs (Java) | Yes |
| 12 | **Podman build** | CI — image build | 4 container images | Yes |
| 13 | **Trivy image** | CI — image scan | OS packages + application libraries | Yes (HIGH/CRIT) |
| 14 | **SonarCloud** | CI — analysis | 3 backend services + frontend | Yes |
| 15 | **Quality Gate** | CI — gate | Four SonarCloud project gates | Yes |
| 16 | **DAST Audit** | Post-deploy staging | https://sample-app.kind.local (Envoy GW + TLS) | Blocks promotion |

---

### Full CI Pipeline — GitHub Actions Skeleton (v4)

```yaml
name: CI Pipeline — v4 (Helm + Envoy Gateway + HTTPS)

on: [push, pull_request]

env:
  CLUSTER_NAME: issue-app
  NAMESPACE: issue-app
  RELEASE_NAME: issue-tracker

jobs:
  pipeline:
    runs-on: ubuntu-latest
    steps:

      # ── Checkout ─────────────────────────────────────────────────────────────
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }

      # ── 1. Gitleaks ──────────────────────────────────────────────────────────
      - name: Gitleaks
        uses: gitleaks/gitleaks-action@v2

      # ── 2. Hadolint ──────────────────────────────────────────────────────────
      - name: Hadolint — all Dockerfiles
        run: find . -name "Dockerfile" | xargs docker run --rm -i hadolint/hadolint hadolint \
               --failure-threshold warning

      # ── 3. Helm lint ─────────────────────────────────────────────────────────
      - name: Setup Helm
        uses: azure/setup-helm@v4
      - name: Helm lint
        run: |
          helm lint helm/issue-tracker
          helm template $RELEASE_NAME helm/issue-tracker \
            --namespace $NAMESPACE > /tmp/rendered.yaml

      # ── 4. Trivy config (Dockerfiles + Helm chart) ───────────────────────────
      - name: Trivy config scan
        run: |
          curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
            | sh -s -- -b /usr/local/bin
          trivy config \
            --exit-code 1 --severity HIGH,CRITICAL \
            --format sarif --output trivy-config.sarif --no-progress \
            .
      - uses: github/codeql-action/upload-sarif@v3
        if: always()
        with: { sarif_file: trivy-config.sarif, category: trivy-config }

      # ── 5. Kubesec ───────────────────────────────────────────────────────────
      - name: Kubesec — rendered manifest risk scoring
        run: |
          curl -sSL https://github.com/controlplaneio/kubesec/releases/latest/download/kubesec_linux_amd64.tar.gz \
            | tar -xz && sudo mv kubesec /usr/local/bin/
          SCORE=$(cat /tmp/rendered.yaml | kubesec scan /dev/stdin | jq '[.[].score] | min')
          echo "Lowest kubesec score: $SCORE"
          [ "$SCORE" -ge 0 ] || exit 1

      # ── 6. kube-score ────────────────────────────────────────────────────────
      - name: kube-score — rendered manifest analysis
        run: |
          curl -Lo /usr/local/bin/kube-score \
            https://github.com/zegl/kube-score/releases/latest/download/kube-score_linux_amd64
          chmod +x /usr/local/bin/kube-score
          kube-score score --exit-one-on-error /tmp/rendered.yaml

      # ── 7 & 9. Checkstyle + Maven Build ──────────────────────────────────────
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

      # ── 9. Semgrep ───────────────────────────────────────────────────────────
      - name: Semgrep SAST
        run: |
          pip install semgrep
          semgrep --config p/spring-security --config p/java \
                  --config p/owasp-top-ten --config p/javascript \
                  --config p/react --config p/dockerfile \
                  --config p/kubernetes --error .

      # ── 11. NVD Check ────────────────────────────────────────────────────────
      - name: NVD Check — auth-service
        run: ./mvnw dependency-check:check
        working-directory: auth-service
        env: { NVD_API_KEY: "${{ secrets.NVD_API_KEY }}" }
      - name: NVD Check — issue-service
        run: ./mvnw dependency-check:check
        working-directory: issue-service
        env: { NVD_API_KEY: "${{ secrets.NVD_API_KEY }}" }
      - uses: actions/setup-node@v4
        with: { node-version: '18' }
      - run: npm ci
        working-directory: frontend-service
      - name: npm audit
        run: npm audit --audit-level=high
        working-directory: frontend-service

      # ── 12. Lint ─────────────────────────────────────────────────────────────
      - name: ESLint
        run: npm run lint
        working-directory: frontend-service
      - name: SpotBugs
        run: ./mvnw spotbugs:check
        working-directory: auth-service

      # ── 13. Build images ──────────────────────────────────────────────────────
      - name: Build Docker images
        run: |
          docker build -t auth-service:ci    ./auth-service
          docker build -t issue-service:ci   ./issue-service
          docker build -t api-gateway:ci     ./api-gateway
          docker build -t frontend-service:ci ./frontend-service

      # ── 14. Trivy image scan ──────────────────────────────────────────────────
      - name: Cache Trivy DB
        uses: actions/cache@v4
        with:
          path: ~/.cache/trivy
          key: trivy-db-${{ github.run_id }}
          restore-keys: trivy-db-
      - name: Download Trivy DB
        run: trivy image --download-db-only --no-progress --cache-dir ~/.cache/trivy
      - name: Trivy image — all services
        run: |
          for SVC in auth-service issue-service api-gateway frontend-service; do
            trivy image \
              --exit-code 1 --severity HIGH,CRITICAL \
              --ignore-unfixed --scanners vuln,secret \
              --cache-dir ~/.cache/trivy --no-progress \
              "${SVC}:ci"
          done

      # ── 15 & 16. SonarQube + Quality Gate ────────────────────────────────────
      - name: SonarQube analysis
        run: |
          ./mvnw sonar:sonar \
            -Dsonar.host.url=${{ secrets.SONAR_HOST }} \
            -Dsonar.login=${{ secrets.SONAR_TOKEN }} \
            -Dsonar.projectKey=issue-tracker-v4
        working-directory: auth-service
      - name: Quality Gate check
        run: |
          STATUS=$(curl -s -u ${{ secrets.SONAR_TOKEN }}: \
            "${{ secrets.SONAR_HOST }}/api/qualitygates/project_status?projectKey=issue-tracker-v4" \
            | jq -r '.projectStatus.status')
          echo "Quality Gate: $STATUS"
          [ "$STATUS" = "OK" ] || exit 1

      # ── Deploy to kind staging ────────────────────────────────────────────────
      - name: Create kind cluster + deploy
        if: github.ref == 'refs/heads/main'
        run: |
          go install sigs.k8s.io/kind@latest
          kind create cluster --name $CLUSTER_NAME --config kind/kind-cluster.yaml
          helm upgrade --install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
            --version v1.2.1 -n envoy-gateway-system --create-namespace --wait
          helm repo add jetstack https://charts.jetstack.io
          helm upgrade --install cert-manager jetstack/cert-manager \
            -n cert-manager --create-namespace --version v1.15.3 \
            --set crds.enabled=true --wait
          docker tag auth-service:ci    auth-service:local
          docker tag issue-service:ci   issue-service:local
          docker tag api-gateway:ci     api-gateway:local
          docker tag frontend-service:ci frontend-service:local
          kind load docker-image auth-service:local    --name $CLUSTER_NAME
          kind load docker-image issue-service:local   --name $CLUSTER_NAME
          kind load docker-image api-gateway:local     --name $CLUSTER_NAME
          kind load docker-image frontend-service:local --name $CLUSTER_NAME
          helm upgrade --install $RELEASE_NAME helm/issue-tracker \
            -n $NAMESPACE --create-namespace --wait --timeout 8m

  # ── 17. DAST ─────────────────────────────────────────────────────────────────
  dast:
    needs: pipeline
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Verify Envoy Gateway
        run: |
          curl -ksf --retry 30 --retry-delay 5 --retry-all-errors \
            https://sample-app.kind.local/api/actuator/health
      - name: OWASP ZAP — HTTPS baseline scan
        uses: zaproxy/action-baseline@v0.12.0
        with:
          target: https://sample-app.kind.local
          cmd_options: "-z '-config network.connection.tlsProtocols.sslv2=false'"
          fail_action: true
```

---

### Required GitHub Secrets (v4)

| Secret | Description |
|---|---|
| `NVD_API_KEY` | Free from https://nvd.nist.gov/developers/request-an-api-key |
| `SONAR_HOST` | SonarQube server URL |
| `SONAR_TOKEN` | SonarQube analysis token |

---

## 14. Automated Verification

`scripts/verify.sh` provides one stable entry point for contributors and CI.
It does not install global tools or start the Kind cluster.

```bash
# Run everything
./scripts/verify.sh all

# Run only the affected area
./scripts/verify.sh backend
./scripts/verify.sh frontend
./scripts/verify.sh helm
./scripts/verify.sh shell
./scripts/verify.sh repo
```

Backend tests use isolated H2 databases and a test-only JWT key. Frontend output
is written under `.verify/`, which is ignored by Git. Helm verification lints and
renders the chart without modifying the current cluster.

The extended security tools in Section 13 remain optional workstation or CI
checks. Store their caches and reports only in the ignored locations documented
in `.gitignore`.
