#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# helm-deploy.sh — Deploy the Issue Tracker to a local kind cluster using Helm
#
# Prerequisites (install before running):
#   brew install kind kubectl helm
#   Docker Desktop must be running
#
# Usage:
#   ./scripts/helm-deploy.sh              # full deploy (cluster + build + install)
#   ./scripts/helm-deploy.sh upgrade      # rebuild images + helm upgrade (no cluster re-create)
#   ./scripts/helm-deploy.sh lint         # helm lint + template dry-run only
#   ./scripts/helm-deploy.sh teardown     # delete the kind cluster
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CLUSTER_NAME="issue-app"
RELEASE_NAME="issue-tracker"
NAMESPACE="issue-app"
CHART_DIR="helm/issue-tracker"
KIND_CLUSTER_CONFIG="kubernetes/environments/kind/kind-cluster.yaml"

# ── Helpers ───────────────────────────────────────────────────────────────────
info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

# ── Subcommands ───────────────────────────────────────────────────────────────
CMD="${1:-deploy}"

# ── Teardown ──────────────────────────────────────────────────────────────────
if [[ "$CMD" == "teardown" ]]; then
  info "Deleting kind cluster '$CLUSTER_NAME'..."
  kind delete cluster --name "$CLUSTER_NAME"
  ok "Cluster deleted."
  exit 0
fi

# ── Validate tools ────────────────────────────────────────────────────────────
for tool in kind kubectl helm docker; do
  command -v "$tool" &>/dev/null || die "'$tool' is not installed. Run: brew install $tool"
done
docker info &>/dev/null || die "Docker is not running. Start Docker Desktop first."

# ── Lint / dry-run only ───────────────────────────────────────────────────────
if [[ "$CMD" == "lint" ]]; then
  info "Linting chart..."
  helm lint "$CHART_DIR"
  info "Rendering templates (dry-run)..."
  helm template "$RELEASE_NAME" "$CHART_DIR" --namespace "$NAMESPACE"
  ok "Lint and dry-run passed."
  exit 0
fi

# ── 1. Create kind cluster (full deploy only) ─────────────────────────────────
if [[ "$CMD" == "deploy" ]]; then
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    info "kind cluster '$CLUSTER_NAME' already exists — skipping creation."
  else
    info "Creating kind cluster '$CLUSTER_NAME'..."
    kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CLUSTER_CONFIG"
    ok "Cluster created."
  fi
fi

# Point kubectl at the cluster
kubectl config use-context "kind-${CLUSTER_NAME}"

# ── 2. Install nginx ingress controller ───────────────────────────────────────
if ! kubectl get ns ingress-nginx &>/dev/null; then
  info "Installing nginx ingress controller..."
  kubectl apply -f \
    https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
  info "Waiting for nginx ingress controller (up to 90 s)..."
  kubectl wait \
    --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=90s
  ok "nginx ingress controller is ready."
else
  info "nginx ingress controller already installed — skipping."
fi

# ── 3. Build Docker images ────────────────────────────────────────────────────
info "Building Docker images..."
docker build -t api-gateway:local      ./api-gateway
docker build -t auth-service:local     ./auth-service
docker build -t issue-service:local    ./issue-service
docker build -t frontend-service:local ./frontend-service
ok "Images built."

# ── 4. Load images into kind ──────────────────────────────────────────────────
info "Loading images into kind cluster '$CLUSTER_NAME'..."
kind load docker-image api-gateway:local      --name "$CLUSTER_NAME"
kind load docker-image auth-service:local     --name "$CLUSTER_NAME"
kind load docker-image issue-service:local    --name "$CLUSTER_NAME"
kind load docker-image frontend-service:local --name "$CLUSTER_NAME"
ok "Images loaded."

# ── 5. Helm install / upgrade ─────────────────────────────────────────────────
info "Running helm upgrade --install '$RELEASE_NAME'..."
helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --wait \
  --timeout 8m \
  --atomic

ok "Helm release '$RELEASE_NAME' deployed."

# ── 6. Status summary ─────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════"
echo "  Issue Tracker is running on kind!"
echo "════════════════════════════════════════════════"
echo ""
echo "  Frontend  →  http://localhost:8080"
echo "  API       →  http://localhost:8080/api"
echo ""
echo "  Default admin credentials:"
echo "    Email:    admin@example.com"
echo "    Password: Admin1234!"
echo ""
echo "  Helm status:"
echo "    helm status $RELEASE_NAME -n $NAMESPACE"
echo ""
echo "  Pod logs:"
echo "    kubectl logs -n $NAMESPACE deploy/auth-service -f"
echo "    kubectl logs -n $NAMESPACE deploy/issue-service -f"
echo "    kubectl logs -n $NAMESPACE deploy/api-gateway -f"
echo ""
echo "  Override any value at deploy time:"
echo "    helm upgrade $RELEASE_NAME $CHART_DIR -n $NAMESPACE \\"
echo "      --set jwt.secret='my-secret' \\"
echo "      --set admin.email='me@example.com'"
echo ""
echo "  Tear down:"
echo "    ./scripts/helm-deploy.sh teardown"
echo "════════════════════════════════════════════════"
