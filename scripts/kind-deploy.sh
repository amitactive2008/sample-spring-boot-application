#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# kind-deploy.sh — Deploy the Issue Tracker to a local kind cluster
#
# Prerequisites (install before running):
#   brew install kind kubectl
#   Docker Desktop must be running
#
# Usage:
#   ./scripts/kind-deploy.sh           # create cluster + build + deploy
#   ./scripts/kind-deploy.sh teardown  # delete the cluster
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CLUSTER_NAME="issue-app"
NAMESPACE="issue-app"
KIND_DIR="kubernetes/environments/kind"

# ── Helpers ───────────────────────────────────────────────────────────────────
info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

# ── Teardown ──────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "teardown" ]]; then
  info "Deleting kind cluster '$CLUSTER_NAME'..."
  kind delete cluster --name "$CLUSTER_NAME"
  ok "Cluster deleted."
  exit 0
fi

# ── Validate tools ────────────────────────────────────────────────────────────
for tool in kind kubectl podman; do
  command -v "$tool" &>/dev/null || die "'$tool' is not installed. See prerequisites in script header."
done

podman info &>/dev/null || die "Podman is not running. Start Podman first."

# ── 1. Create kind cluster ────────────────────────────────────────────────────
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  info "kind cluster '$CLUSTER_NAME' already exists — skipping creation."
else
  info "Creating kind cluster '$CLUSTER_NAME'..."
  kind create cluster --name "$CLUSTER_NAME" --config "$KIND_DIR/kind-cluster.yaml"
  ok "Cluster created."
fi

# Point kubectl at the new cluster
kubectl config use-context "kind-${CLUSTER_NAME}"

# ── 2. Install nginx ingress controller ───────────────────────────────────────
info "Installing nginx ingress controller..."
kubectl apply -f \
  https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

info "Waiting for nginx ingress controller to become ready (up to 90 s)..."
kubectl wait \
  --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s
ok "nginx ingress controller is ready."

# ── 3. Build Docker images ────────────────────────────────────────────────────
info "Building Docker images (this takes a few minutes on first run)..."
podman build -t api-gateway:local     ./api-gateway
podman build -t auth-service:local    ./auth-service
podman build -t issue-service:local   ./issue-service
podman build -t frontend-service:local ./frontend-service
ok "Images built."

# ── 4. Load images into kind ──────────────────────────────────────────────────
info "Loading images into kind cluster..."
kind load podman-image api-gateway:local      --name "$CLUSTER_NAME"
kind load podman-image auth-service:local     --name "$CLUSTER_NAME"
kind load podman-image issue-service:local    --name "$CLUSTER_NAME"
kind load podman-image frontend-service:local --name "$CLUSTER_NAME"
ok "Images loaded."

# ── 5. Deploy via Kustomize ───────────────────────────────────────────────────
info "Applying Kubernetes manifests..."
kubectl apply -k "$KIND_DIR"
ok "Manifests applied."

# ── 6. Wait for MySQL to be ready ─────────────────────────────────────────────
info "Waiting for MySQL to be ready (up to 2 min)..."
kubectl wait \
  --namespace "$NAMESPACE" \
  --for=condition=ready pod \
  --selector=app=mysql \
  --timeout=120s
ok "MySQL is ready."

# ── 7. Wait for application pods ─────────────────────────────────────────────
info "Waiting for all application pods to be ready (up to 5 min)..."
for svc in api-gateway auth-service issue-service frontend-service; do
  info "  waiting for $svc..."
  kubectl wait \
    --namespace "$NAMESPACE" \
    --for=condition=ready pod \
    --selector="app=$svc" \
    --timeout=300s
done
ok "All pods are ready."

# ── Done ──────────────────────────────────────────────────────────────────────
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
echo "  Useful commands:"
echo "    kubectl get pods -n $NAMESPACE"
echo "    kubectl logs -n $NAMESPACE deploy/auth-service -f"
echo "    kubectl logs -n $NAMESPACE deploy/issue-service -f"
echo "    kubectl logs -n $NAMESPACE deploy/api-gateway -f"
echo ""
echo "  Tear down:"
echo "    ./scripts/kind-deploy.sh teardown"
echo "════════════════════════════════════════════════"
