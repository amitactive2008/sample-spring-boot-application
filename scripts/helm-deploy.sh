#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# helm-deploy.sh — Deploy Issue Tracker to a local kind cluster
#                  using Helm + Envoy Gateway + cert-manager (HTTPS)
#
# Prerequisites (install before running):
#   brew install kind kubectl helm docker
#   Docker Desktop (or equivalent) must be running.
#
# Usage:
#   ./scripts/helm-deploy.sh              # full deploy  (cluster + infra + app)
#   ./scripts/helm-deploy.sh upgrade      # rebuild images + helm upgrade only
#   ./scripts/helm-deploy.sh pf           # (re)start port-forward on existing cluster
#   ./scripts/helm-deploy.sh lint         # helm lint + dry-run + security checks
#   ./scripts/helm-deploy.sh teardown     # delete the kind cluster
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
CLUSTER_NAME="issue-app"
RELEASE_NAME="issue-tracker"
NAMESPACE="issue-app"
CHART_DIR="helm/issue-tracker"
KIND_CLUSTER_CONFIG="kind/kind-cluster.yaml"

GATEWAY_NAME="issue-tracker-gateway"
GATEWAY_NAMESPACE="${NAMESPACE}"

# Component versions — pin these for reproducible deploys
ENVOY_GW_VERSION="v1.2.1"
CERT_MANAGER_VERSION="v1.15.3"
GATEWAY_API_CRD_VERSION="v1.2.0"

# Host ports (must match kind/kind-cluster.yaml extraPortMappings)
HTTP_HOST_PORT=8080
HTTPS_HOST_PORT=8443

# ── Helpers ───────────────────────────────────────────────────────────────────
info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
warn()  { echo "[WARN]  $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

# ── Tool validation ───────────────────────────────────────────────────────────
validate_tools() {
  for tool in kind kubectl helm docker; do
    command -v "$tool" &>/dev/null || die "'$tool' is not installed. Run: brew install $tool"
  done
  docker info &>/dev/null || die "Docker is not running. Start Docker Desktop first."
  [[ -f "$KIND_CLUSTER_CONFIG" ]] || die "kind cluster config not found: $KIND_CLUSTER_CONFIG"
}

# ── Subcommand: teardown ──────────────────────────────────────────────────────
if [[ "${1:-}" == "teardown" ]]; then
  info "Stopping any running port-forwards..."
  if [[ -f /tmp/issue-tracker-pf.pid ]]; then
    PF_PID=$(cat /tmp/issue-tracker-pf.pid)
    kill "$PF_PID" 2>/dev/null && info "  Port-forward (PID $PF_PID) stopped." || true
    rm -f /tmp/issue-tracker-pf.pid
  fi
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

# ── Port-forward helper function ──────────────────────────────────────────────
start_port_forward() {
  info "Discovering Envoy proxy Service for Gateway '${GATEWAY_NAME}'..."

  local ENVOY_SVC=""
  for i in $(seq 1 36); do
    ENVOY_SVC=$(kubectl get svc -n "${GATEWAY_NAMESPACE}" \
      --selector="gateway.envoyproxy.io/owning-gateway-name=${GATEWAY_NAME}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [[ -n "$ENVOY_SVC" ]] && break
    info "  Waiting for Envoy Service... ($i/36, sleeping 5s)"
    sleep 5
  done

  [[ -n "$ENVOY_SVC" ]] || die "Envoy Service not found for Gateway '${GATEWAY_NAME}' after 3 min"
  info "  Found Envoy Service: ${ENVOY_SVC}"

  # Stop any existing port-forward for this release
  if [[ -f /tmp/issue-tracker-pf.pid ]]; then
    OLD_PID=$(cat /tmp/issue-tracker-pf.pid)
    kill "$OLD_PID" 2>/dev/null || true
    rm -f /tmp/issue-tracker-pf.pid
  fi

  # Start port-forward in background
  kubectl port-forward \
    -n "${GATEWAY_NAMESPACE}" \
    "svc/${ENVOY_SVC}" \
    "${HTTP_HOST_PORT}:80" \
    "${HTTPS_HOST_PORT}:443" \
    >/tmp/issue-tracker-pf.log 2>&1 &
  PF_PID=$!
  echo "${PF_PID}" > /tmp/issue-tracker-pf.pid

  # Give it a moment to establish
  sleep 2
  kill -0 "$PF_PID" 2>/dev/null || die "Port-forward failed to start. See /tmp/issue-tracker-pf.log"
  ok "Port-forward started (PID: ${PF_PID})"
  info "  Log: /tmp/issue-tracker-pf.log"
  info "  To stop: kill ${PF_PID}  (or ./scripts/helm-deploy.sh teardown)"
}

# ── Subcommand: pf (start/restart port-forward only) ─────────────────────────
if [[ "${1:-}" == "pf" ]]; then
  validate_tools
  kubectl config use-context "kind-${CLUSTER_NAME}" \
    || die "kind cluster '${CLUSTER_NAME}' not found. Run the full deploy first."
  start_port_forward
  echo ""
  echo "  HTTP  →  http://localhost:${HTTP_HOST_PORT}   (redirects to HTTPS)"
  echo "  HTTPS →  https://localhost:${HTTPS_HOST_PORT}"
  exit 0
fi

# ── Validate tools for full deploy / upgrade ──────────────────────────────────
validate_tools
CMD="${1:-deploy}"
[[ "$CMD" == "deploy" || "$CMD" == "upgrade" ]] || die "Unknown subcommand: $CMD"

# ── 1. Create kind cluster (deploy only) ─────────────────────────────────────
if [[ "$CMD" == "deploy" ]]; then
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    info "kind cluster '${CLUSTER_NAME}' already exists — skipping creation."
  else
    info "Creating kind cluster '${CLUSTER_NAME}'..."
    kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CLUSTER_CONFIG"
    ok "Cluster created."
  fi
fi

kubectl config use-context "kind-${CLUSTER_NAME}"

# ── 2. Install Gateway API CRDs ───────────────────────────────────────────────
# Envoy Gateway requires the Gateway API CRDs (GatewayClass, Gateway, HTTPRoute, etc.)
# to be installed before the Envoy Gateway controller itself.
info "Installing Gateway API CRDs (${GATEWAY_API_CRD_VERSION})..."
kubectl apply -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_CRD_VERSION}/standard-install.yaml"
ok "Gateway API CRDs installed."

# ── 3. Install Envoy Gateway via Helm ─────────────────────────────────────────
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

# ── 4. Install cert-manager via Helm ──────────────────────────────────────────
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

# ── 5. Build Docker images ────────────────────────────────────────────────────
info "Building Docker images..."
docker build -t api-gateway:local      ./api-gateway
docker build -t auth-service:local     ./auth-service
docker build -t issue-service:local    ./issue-service
docker build -t frontend-service:local ./frontend-service
ok "Images built."

# ── 6. Load images into kind ──────────────────────────────────────────────────
info "Loading images into kind cluster '${CLUSTER_NAME}'..."
kind load docker-image api-gateway:local      --name "$CLUSTER_NAME"
kind load docker-image auth-service:local     --name "$CLUSTER_NAME"
kind load docker-image issue-service:local    --name "$CLUSTER_NAME"
kind load docker-image frontend-service:local --name "$CLUSTER_NAME"
ok "Images loaded."

# ── 7. Helm install / upgrade ─────────────────────────────────────────────────
info "Running helm upgrade --install '${RELEASE_NAME}'..."
helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --wait \
  --timeout 8m \
  --atomic

ok "Helm release '${RELEASE_NAME}' deployed."

# ── 8. Wait for cert-manager to issue the TLS certificate ─────────────────────
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

# ── 9. Start port-forward ─────────────────────────────────────────────────────
start_port_forward

# ── Done ──────────────────────────────────────────────────────────────────────
cat <<EOF

════════════════════════════════════════════════════════════
  Issue Tracker — running on kind with HTTPS!
════════════════════════════════════════════════════════════

  Frontend  →  https://localhost:${HTTPS_HOST_PORT}
  API       →  https://localhost:${HTTPS_HOST_PORT}/api
  HTTP      →  http://localhost:${HTTP_HOST_PORT}  (redirects → HTTPS)

  TLS: self-signed certificate from cert-manager
  Browser will show "untrusted" warning — click "Advanced → Proceed".
  To suppress the warning, import the CA cert (see README Section 6.5).

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
      --set gatewayAPI.hostname='issue-tracker.local'

  Tear down:
    ./scripts/helm-deploy.sh teardown
════════════════════════════════════════════════════════════
EOF
