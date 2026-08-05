#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# helm-deploy.sh — Deploy Issue Tracker to a local kind cluster
#                  using Helm + Envoy Gateway + cert-manager (HTTPS)
#
# Prerequisites (install before running):
#   brew install kind kubectl helm podman
#   Podman machine must be running: podman machine start
#
# Usage:
#   ./scripts/helm-deploy.sh              # full deploy  (cluster + infra + app)
#   ./scripts/helm-deploy.sh upgrade      # rebuild images + helm upgrade only
#   ./scripts/helm-deploy.sh check        # verify existing cluster endpoints
#   ./scripts/helm-deploy.sh lint         # helm lint + dry-run + security checks
#   ./scripts/helm-deploy.sh teardown     # delete the kind cluster
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# kind's Podman provider is experimental and must be selected explicitly.
export KIND_EXPERIMENTAL_PROVIDER=podman

# ── Configuration ─────────────────────────────────────────────────────────────
CLUSTER_NAME="issue-app"
RELEASE_NAME="issue-tracker"
NAMESPACE="issue-app"
CHART_DIR="helm/issue-tracker"
KIND_CLUSTER_CONFIG="kind/kind-cluster.yaml"

# Component versions — pin these for reproducible deploys
ENVOY_GW_VERSION="v1.2.1"
CERT_MANAGER_VERSION="v1.15.3"

# Host ports (must match kind/kind-cluster.yaml extraPortMappings)
HTTP_HOST_PORT=80
HTTPS_HOST_PORT=443
APP_HOST="sample-app.kind.local"

# Podman qualifies unregistered image names with localhost/. The Helm values
# use the same names so imagePullPolicy=Never resolves the pre-loaded images.
IMAGES=(
  "localhost/api-gateway:local"
  "localhost/auth-service:local"
  "localhost/issue-service:local"
  "localhost/frontend-service:local"
)

# ── Helpers ───────────────────────────────────────────────────────────────────
info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
warn()  { echo "[WARN]  $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

# ── Tool validation ───────────────────────────────────────────────────────────
validate_tools() {
  for tool in kind kubectl helm podman curl; do
    command -v "$tool" &>/dev/null || die "'$tool' is not installed. Run: brew install $tool"
  done
  podman info &>/dev/null || die "Podman is not running. Start it with: podman machine start"
  [[ -f "$KIND_CLUSTER_CONFIG" ]] || die "kind cluster config not found: $KIND_CLUSTER_CONFIG"
}

cluster_exists() {
  podman container exists "${CLUSTER_NAME}-control-plane"
}

# ── Subcommand: teardown ──────────────────────────────────────────────────────
if [[ "${1:-}" == "teardown" ]]; then
  info "Deleting kind cluster '$CLUSTER_NAME'..."
  kind delete cluster --name "$CLUSTER_NAME"
  ok "Cluster deleted."
  exit 0
fi

# ── Subcommand: lint ──────────────────────────────────────────────────────────
if [[ "${1:-}" == "lint" ]]; then
  validate_tools
  info "── Helm lint ────────────────────────────────────────────────────────────"
  helm lint "$CHART_DIR"

  info "── Helm template (dry-run render) ───────────────────────────────────────"
  RENDERED=$(helm template "$RELEASE_NAME" "$CHART_DIR" \
    --namespace "$NAMESPACE" \
    --set global.imagePullPolicy=Never)

  info "── kubesec (manifest security risk scoring) ─────────────────────────────"
  if command -v kubesec &>/dev/null; then
    echo "$RENDERED" | kubesec scan /dev/stdin || warn "kubesec found issues — review above"
  else
    warn "kubesec not installed — skipping (brew install kubesec)"
  fi

  info "── kube-score (K8s best-practice analysis) ──────────────────────────────"
  if command -v kube-score &>/dev/null; then
    echo "$RENDERED" | kube-score score - || warn "kube-score found issues — review above"
  else
    warn "kube-score not installed — skipping (brew install kube-score)"
  fi

  info "── Trivy config (Helm chart + Dockerfile misconfigurations) ────────────"
  if command -v trivy &>/dev/null; then
    trivy config "$CHART_DIR" || warn "trivy config found issues — review above"
    find . -name "Dockerfile" | while read -r df; do
      trivy config "$df" || warn "trivy found issues in $df"
    done
  else
    warn "trivy not installed — skipping (brew install trivy)"
  fi

  info "── Hadolint (Dockerfile best-practice lint) ─────────────────────────────"
  if command -v hadolint &>/dev/null; then
    find . -name "Dockerfile" | xargs hadolint --failure-threshold warning || \
      warn "hadolint found issues — review above"
  else
    warn "hadolint not installed — skipping (brew install hadolint)"
  fi

  ok "Lint and security checks complete."
  exit 0
fi

# ── Gateway verification ──────────────────────────────────────────────────────
verify_gateway() {
  info "Waiting for Envoy Gateway at https://${APP_HOST}..."
  for attempt in $(seq 1 36); do
    if curl -ksf --noproxy '*' --max-time 5 \
      --resolve "${APP_HOST}:${HTTPS_HOST_PORT}:127.0.0.1" \
      "https://${APP_HOST}/" >/dev/null 2>&1; then
      ok "HTTPS frontend is reachable."
      curl -ksf --noproxy '*' --max-time 10 \
        --resolve "${APP_HOST}:${HTTPS_HOST_PORT}:127.0.0.1" \
        "https://${APP_HOST}/api/actuator/health" >/dev/null \
        || die "Frontend is reachable, but the API gateway health route failed."
      ok "API gateway health route is reachable."
      return 0
    fi
    info "  Waiting for Envoy listener... (${attempt}/36, sleeping 5s)"
    sleep 5
  done
  die "Envoy Gateway did not become reachable. Check: kubectl get gateway,pods -A"
}

# ── Subcommand: check existing deployment ─────────────────────────────────────
if [[ "${1:-}" == "check" || "${1:-}" == "pf" ]]; then
  validate_tools
  kubectl config use-context "kind-${CLUSTER_NAME}" \
    || die "kind cluster '${CLUSTER_NAME}' not found. Run the full deploy first."
  [[ "${1:-}" == "pf" ]] && warn "The 'pf' command is deprecated; direct Kind port mappings are used."
  verify_gateway
  echo ""
  echo "  HTTP  →  http://${APP_HOST}   (redirects to HTTPS)"
  echo "  HTTPS →  https://${APP_HOST}"
  exit 0
fi

# ── Validate tools for full deploy / upgrade ──────────────────────────────────
validate_tools
CMD="${1:-deploy}"
[[ "$CMD" == "deploy" || "$CMD" == "upgrade" ]] || die "Unknown subcommand: $CMD"

# ── 1. Create kind cluster (deploy only) ─────────────────────────────────────
if [[ "$CMD" == "deploy" ]]; then
  if cluster_exists; then
    info "kind cluster '${CLUSTER_NAME}' already exists — skipping creation."
  else
    info "Creating kind cluster '${CLUSTER_NAME}'..."
    kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CLUSTER_CONFIG"
    ok "Cluster created."
  fi
fi

if ! cluster_exists; then
  die "kind cluster '${CLUSTER_NAME}' does not exist. Run './scripts/helm-deploy.sh' first."
fi

kubectl config use-context "kind-${CLUSTER_NAME}"

# ── 2. Install Envoy Gateway and its compatible Gateway API CRDs ──────────────
# The pinned chart owns both Envoy Gateway and Gateway API CRDs. Installing a
# second CRD bundle with kubectl causes Helm field-manager conflicts.
if ! kubectl get ns envoy-gateway-system &>/dev/null 2>&1 || [[ "$CMD" == "upgrade" ]]; then
  info "Installing Envoy Gateway (${ENVOY_GW_VERSION})..."
  helm upgrade --install envoy-gateway \
    oci://docker.io/envoyproxy/gateway-helm \
    --version "${ENVOY_GW_VERSION}" \
    --namespace envoy-gateway-system \
    --create-namespace \
    --wait \
    --timeout 3m
  ok "Envoy Gateway installed."
else
  info "Envoy Gateway already installed — skipping."
fi

# ── 3. Install cert-manager via Helm ──────────────────────────────────────────
if ! kubectl get ns cert-manager &>/dev/null 2>&1 || [[ "$CMD" == "upgrade" ]]; then
  info "Installing cert-manager (${CERT_MANAGER_VERSION})..."
  helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version "${CERT_MANAGER_VERSION}" \
    --set crds.enabled=true \
    --wait \
    --timeout 3m
  ok "cert-manager installed."
else
  info "cert-manager already installed — skipping."
fi

# Wait for cert-manager webhook to be fully ready (it can be slow)
info "Waiting for cert-manager webhook to be ready..."
kubectl wait deployment/cert-manager-webhook \
  --namespace cert-manager \
  --for=condition=Available \
  --timeout=60s
ok "cert-manager webhook is ready."

# ── 4. Build container images with Podman ─────────────────────────────────────
info "Building container images with Podman..."
podman build -t localhost/api-gateway:local       ./api-gateway
podman build -t localhost/auth-service:local      ./auth-service
podman build -t localhost/issue-service:local     ./issue-service
podman build -t localhost/frontend-service:local  ./frontend-service
ok "Images built."

# ── 5. Load images into kind ──────────────────────────────────────────────────
info "Loading images into kind cluster '${CLUSTER_NAME}'..."
IMAGE_ARCHIVE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/issue-tracker-images.XXXXXX")
cleanup_image_archives() {
  rm -rf "$IMAGE_ARCHIVE_DIR"
}
trap cleanup_image_archives EXIT

for image in "${IMAGES[@]}"; do
  archive_name=${image#localhost/}
  archive_name=${archive_name//[:\/]/-}
  archive_path="${IMAGE_ARCHIVE_DIR}/${archive_name}.tar"
  info "  Loading ${image}..."
  podman save --output "$archive_path" "$image"
  kind load image-archive "$archive_path" --name "$CLUSTER_NAME"
done
ok "Images loaded."

# ── 6. Helm install / upgrade ─────────────────────────────────────────────────
info "Running helm upgrade --install '${RELEASE_NAME}'..."
helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --wait \
  --timeout 8m \
  --atomic

ok "Helm release '${RELEASE_NAME}' deployed."

# ── 7. Wait for cert-manager to issue the TLS certificate ─────────────────────
info "Waiting for cert-manager to issue TLS certificate (up to 2 min)..."
for i in $(seq 1 24); do
  CERT_READY=$(kubectl get certificate -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  [[ "$CERT_READY" == "True" ]] && break
  info "  Certificate not ready yet ($i/24)... sleeping 5s"
  sleep 5
done

if [[ "$CERT_READY" == "True" ]]; then
  ok "TLS certificate issued."
else
  warn "Certificate not ready after 2 min — check: kubectl describe certificate -n ${NAMESPACE}"
fi

# ── 8. Verify the direct Kind port mappings ───────────────────────────────────
verify_gateway

# ── Done ──────────────────────────────────────────────────────────────────────
cat <<EOF

════════════════════════════════════════════════════════════
  Issue Tracker — running on kind with HTTPS!
════════════════════════════════════════════════════════════

  Frontend  →  https://${APP_HOST}
  API       →  https://${APP_HOST}/api
  HTTP      →  http://${APP_HOST}  (redirects → HTTPS)

  TLS: self-signed certificate from cert-manager
  Browser will show "untrusted" warning — click "Advanced → Proceed".
  To suppress the warning, import the CA cert (see README Section 6.9).

  Admin credentials:
    Email   :  admin@example.com
    Password:  Admin1234!

  Useful commands:
    kubectl get pods -n ${NAMESPACE}
    kubectl get httproute,gateway,certificate -n ${NAMESPACE}
    helm status ${RELEASE_NAME} -n ${NAMESPACE}
    kubectl logs -n ${NAMESPACE} deploy/auth-service -f

  Helm overrides at deploy time:
    helm upgrade ${RELEASE_NAME} ${CHART_DIR} -n ${NAMESPACE} \\
      --set jwt.secret='my-secret' \\
      --set admin.email='me@example.com' \\
      --set gatewayAPI.hostname='sample-app.kind.local'

  Tear down:
    ./scripts/helm-deploy.sh teardown
════════════════════════════════════════════════════════════
EOF
