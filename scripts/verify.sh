#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scope="${1:-all}"

verify_backend() {
  local service
  for service in api-gateway auth-service issue-service; do
    echo "Verifying ${service}"
    (
      cd "${repository_root}/${service}"
      ./mvnw test -B --no-transfer-progress
    )
  done
}

verify_frontend() {
  cd "${repository_root}/frontend-service"
  [[ -d node_modules ]] || npm ci
  npm run lint
  npm test -- --watchAll=false --passWithNoTests
  BUILD_PATH="${repository_root}/.verify/frontend-build" npm run build
}

verify_manifests() {
  command -v kubectl >/dev/null 2>&1 || {
    echo "kubectl is required to render the kind overlay" >&2
    return 1
  }

  kubectl kustomize "${repository_root}/kubernetes/environments/kind" \
    --load-restrictor=LoadRestrictionsNone >/dev/null
  echo "kind Kustomize overlay is valid"
}

verify_shell() {
  bash -n \
    "${repository_root}/scripts/kind-deploy.sh" \
    "${repository_root}/scripts/verify.sh" \
    "${repository_root}/security-pipeline.sh"
  echo "shell scripts are syntactically valid"
}

case "$scope" in
  backend) verify_backend ;;
  frontend) verify_frontend ;;
  manifests) verify_manifests ;;
  shell) verify_shell ;;
  all)
    verify_backend
    verify_frontend
    verify_manifests
    verify_shell
    ;;
  *)
    echo "Usage: $0 [backend|frontend|manifests|shell|all]" >&2
    exit 2
    ;;
esac
