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
for tool in kind kubectl podman helm curl; do
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
  if command -v lsof &>/dev/null && lsof -nP -iTCP:80 -sTCP:LISTEN | grep -q .; then
    lsof -nP -iTCP:80 -sTCP:LISTEN >&2
    die "Host port 80 is already in use. Stop that process before creating the cluster."
  fi
  info "Creating kind cluster '$CLUSTER_NAME' (using Podman)..."
  kind create cluster --name "$CLUSTER_NAME" --config "$KIND_DIR/kind-cluster.yaml"
  ok "Cluster created."
fi

# Kind port mappings are fixed when the control-plane container is created.
control_plane_container="${CLUSTER_NAME}-control-plane"
port_mapping=$(podman port "$control_plane_container" 80/tcp 2>/dev/null || true)
if ! grep -Eq ':80$' <<< "$port_mapping"; then
  die "Cluster '$CLUSTER_NAME' was not created with host port 80. Run './scripts/kind-deploy.sh teardown' and deploy again."
fi

# Point kubectl at the cluster
kubectl config use-context "kind-${CLUSTER_NAME}"

# ── 2. Install nginx ingress controller ───────────────────────────────────────
info "Installing nginx ingress controller..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -f scripts/values.yaml \
  --namespace ingress-nginx \
  --create-namespace

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
# Apply the frontend Ingress first when upgrading an older combined Ingress.
# This releases its /api path before the admission webhook validates the new,
# separate API Ingress.
kubectl apply -f "$KIND_DIR/ingress.yaml"
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

# ── 8. Verify host → kind → ingress → frontend ───────────────────────────────
info "Waiting for the frontend through nginx Ingress at http://localhost..."
ingress_ready=false
for _ in $(seq 1 30); do
  if curl -fsS --max-time 5 http://localhost/ >/dev/null 2>&1; then
    ingress_ready=true
    break
  fi
  sleep 2
done

if [[ "$ingress_ready" != "true" ]]; then
  warn "Ingress controller status:"
  kubectl get pods -n ingress-nginx -o wide >&2 || true
  warn "Ingress resources status:"
  kubectl describe ingress -n "$NAMESPACE" >&2 || true
  die "Frontend is not reachable at http://localhost"
fi

# A rewrite annotation affects every path in its Ingress. Verify that the API
# rewrite has not accidentally turned a frontend JavaScript request into HTML.
asset_content_type=$(
  curl -fsSI --max-time 10 http://localhost/static/js/bundle.js 2>/dev/null \
    | awk -F ': *' 'tolower($1) == "content-type" { print tolower($2) }' \
    | tr -d '\r' \
    || true
)
if [[ "$asset_content_type" != application/javascript* ]]; then
  die "Frontend asset routing is invalid: /static/js/bundle.js returned '${asset_content_type:-no content type}'"
fi
ok "Frontend is reachable through nginx Ingress."

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════"
echo "  Issue Tracker is running on kind!"
echo "════════════════════════════════════════════════"
echo ""
echo "  Frontend  →  http://localhost"
echo "              http://microservices-ingress.localhost"
echo "  API       →  http://localhost/api"
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
