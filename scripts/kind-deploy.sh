#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# kind-deploy.sh — Deploy the Issue Tracker to a local kind cluster
#
# Prerequisites:
#   brew install kind kubectl
#   Podman must be installed and its machine must be running:
#     podman machine start
#
# Usage:
#   ./scripts/kind-deploy.sh           # create cluster + build + deploy
#   ./scripts/kind-deploy.sh teardown  # delete the cluster
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CLUSTER_NAME="issue-app"
NAMESPACE="issue-app"
KIND_DIR="kubernetes/environments/kind"

# Image names — Podman always qualifies unregistered names with "localhost/",
# so the tag in kind's containerd becomes localhost/<name>:local.
# The kustomization.yaml image overrides use the same prefix.
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

# Wait for pods matching a label selector to exist, then wait for Ready.
# Usage: wait_for_pods <namespace> <selector> <timeout_seconds> <description>
wait_for_pods() {
  local ns="$1" selector="$2" timeout="$3" desc="$4"
  local deadline=$(( $(date +%s) + timeout ))

  info "Waiting for $desc pods to be created..."
  until kubectl get pods -n "$ns" -l "$selector" --no-headers 2>/dev/null | grep -q .; do
    if [[ $(date +%s) -gt $deadline ]]; then
      die "Timed out waiting for $desc pods to be created"
    fi
    sleep 3
  done

  info "Waiting for $desc to be Ready (up to ${timeout}s)..."
  kubectl wait \
    --namespace "$ns" \
    --for=condition=ready pod \
    --selector="$selector" \
    --timeout="${timeout}s"
  ok "$desc is Ready."
}

# ── Teardown ──────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "teardown" ]]; then
  info "Deleting kind cluster '$CLUSTER_NAME'..."
  KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name "$CLUSTER_NAME"
  ok "Cluster deleted."
  exit 0
fi

# ── Validate tools ────────────────────────────────────────────────────────────
for tool in kind kubectl podman; do
  command -v "$tool" &>/dev/null || die "'$tool' is not installed. Install with: brew install $tool"
done

# Ensure the Podman machine is running
if ! podman machine list 2>/dev/null | grep -q "Currently running"; then
  die "Podman machine is not running. Start it with: podman machine start"
fi
ok "Podman machine is running."

# ── 1. Create kind cluster (using Podman as the container runtime) ────────────
export KIND_EXPERIMENTAL_PROVIDER=podman

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  info "kind cluster '$CLUSTER_NAME' already exists — skipping creation."
else
  info "Creating kind cluster '$CLUSTER_NAME' (using Podman)..."
  kind create cluster --name "$CLUSTER_NAME" --config "$KIND_DIR/kind-cluster.yaml"
  ok "Cluster created."
fi

# Point kubectl at the cluster
kubectl config use-context "kind-${CLUSTER_NAME}"

# ── 2. Install nginx ingress controller ───────────────────────────────────────
info "Installing nginx ingress controller..."
helm install ingress-nginx ./ingress-nginx \
  -f scripts/values.yaml \
  --namespace ingress-nginx --create-namespace

# Use rollout status — tolerates the pods not yet being scheduled
info "Waiting for nginx ingress controller to become ready (up to 120s)..."
kubectl rollout status deployment/ingress-nginx-controller \
  -n ingress-nginx \
  --timeout=120s
ok "nginx ingress controller is ready."

# ── 3. Build container images with Podman ─────────────────────────────────────
info "Building container images with Podman (first run takes a few minutes)..."
podman build -t localhost/api-gateway:local     ./api-gateway
podman build -t localhost/auth-service:local    ./auth-service
podman build -t localhost/issue-service:local   ./issue-service
podman build -t localhost/frontend-service:local ./frontend-service
ok "Images built."

# ── 4. Load images into kind via image archive ────────────────────────────────
# kind load docker-image requires Docker daemon; instead pipe through podman save
info "Loading images into kind cluster (this may take a minute)..."
for img in "${IMAGES[@]}"; do
  info "  loading $img..."
  podman save "$img" | kind load image-archive /dev/stdin --name "$CLUSTER_NAME"
done
ok "All images loaded into kind."

# ── 5. Deploy via Kustomize ───────────────────────────────────────────────────
# kubectl apply -k is blocked by Kustomize v5 security when patches reference
# files outside the kustomization root (../../base/...).
# Workaround: build with --load-restrictor=LoadRestrictionsNone then apply.
info "Applying Kubernetes manifests (Kustomize)..."
kubectl kustomize "$KIND_DIR" --load-restrictor=LoadRestrictionsNone \
  | kubectl apply -f -
ok "Manifests applied."

# ── 6. Wait for MySQL ─────────────────────────────────────────────────────────
wait_for_pods "$NAMESPACE" "app=mysql" 180 "MySQL"

# ── 7. Wait for application pods ─────────────────────────────────────────────
info "Waiting for application pods to be Ready (up to 5 min each)..."
for svc in api-gateway auth-service issue-service frontend-service; do
  wait_for_pods "$NAMESPACE" "app=$svc" 300 "$svc"
done

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
echo "    kubectl logs -n $NAMESPACE deploy/auth-service  -f"
echo "    kubectl logs -n $NAMESPACE deploy/issue-service -f"
echo "    kubectl logs -n $NAMESPACE deploy/api-gateway   -f"
echo "    kubectl logs -n $NAMESPACE deploy/mysql         -f"
echo ""
echo "  Tear down:"
echo "    ./scripts/kind-deploy.sh teardown"
echo "════════════════════════════════════════════════"
