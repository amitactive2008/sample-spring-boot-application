#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scope="${1:-all}"

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required tool not found: $1" >&2
    return 1
  }
}

verify_backend() {
  require_tool java

  local service
  for service in api-gateway auth-service issue-service; do
    echo "==> Testing ${service}"
    (
      cd "${repository_root}/${service}"
      ./mvnw test -B --no-transfer-progress
    )
  done
}

verify_frontend() {
  require_tool npm
  cd "${repository_root}/frontend-service"

  [[ -d node_modules ]] || npm ci
  npm run lint
  CI=true npm test -- --watchAll=false --passWithNoTests
  BUILD_PATH="${repository_root}/.verify/frontend-build" \
    NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=1024}" \
    npm run build
}

verify_helm() {
  require_tool helm
  helm lint "${repository_root}/helm/issue-tracker"
  helm template issue-tracker "${repository_root}/helm/issue-tracker" \
    --namespace issue-app \
    --set global.imagePullPolicy=Never >/dev/null
  echo "Helm chart lint and render passed"
}

verify_shell() {
  bash -n \
    "${repository_root}/security-pipeline.sh" \
    "${repository_root}/scripts/helm-deploy.sh" \
    "${repository_root}/scripts/verify.sh"
  echo "Shell syntax checks passed"
}

verify_repository() {
  git -C "${repository_root}" diff --check
  echo "Git whitespace checks passed"
}

case "${scope}" in
  backend) verify_backend ;;
  frontend) verify_frontend ;;
  helm) verify_helm ;;
  shell) verify_shell ;;
  repo) verify_repository ;;
  all)
    verify_backend
    verify_frontend
    verify_helm
    verify_shell
    verify_repository
    ;;
  *)
    echo "Usage: $0 [backend|frontend|helm|shell|repo|all]" >&2
    exit 2
    ;;
esac
