#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scope="${1:-all}"

verify_backend() {
  local service
  for service in api-gateway auth-service issue-service; do
    echo "Verifying ${service}"
    (cd "${repository_root}/${service}" && ./mvnw test)
  done
}

verify_frontend() {
  cd "${repository_root}/frontend-service"

  if [[ ! -d node_modules ]]; then
    echo "Installing frontend dependencies with npm ci"
    npm ci
  fi

  npm run lint
  CI=true npm test -- --watchAll=false --passWithNoTests
  BUILD_PATH="${repository_root}/.verify/frontend-build" npm run build
}

case "${scope}" in
  backend)
    verify_backend
    ;;
  frontend)
    verify_frontend
    ;;
  all)
    verify_backend
    verify_frontend
    ;;
  *)
    echo "Usage: $0 [backend|frontend|all]" >&2
    exit 2
    ;;
esac
