#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
MACHINE_NAME="${1:-issue-tracker-v1}"
FRONTEND_DIR="${REPO_DIR}/frontend-service"
BUILD_DIR="${FRONTEND_DIR}/build"

command -v orbctl >/dev/null 2>&1 || {
  echo "orbctl is required. Install and start OrbStack first." >&2
  exit 1
}

if [[ ! -d "${FRONTEND_DIR}/node_modules" ]]; then
  echo "frontend-service/node_modules is missing." >&2
  echo "Run 'npm ci' in frontend-service on the Mac, then retry." >&2
  exit 1
fi

echo "Building the React frontend on the Mac..."
(
  cd "${FRONTEND_DIR}"
  REACT_APP_API_BASE_URL="" npm run build
)

test -f "${BUILD_DIR}/index.html" || {
  echo "Frontend build did not create ${BUILD_DIR}/index.html" >&2
  exit 1
}

echo "Copying the static frontend to ${MACHINE_NAME}..."
orbctl run -m "${MACHINE_NAME}" sudo bash -c '
  set -euo pipefail
  source_dir="$1"
  target_dir=/opt/issue-tracker/frontend-service/build
  install -d -m 0755 "${target_dir}"
  cp -R "${source_dir}/." "${target_dir}/"
  chown -R issueapp:issueapp "${target_dir}"
  systemctl reload nginx
  test -f "${target_dir}/index.html"
' _ "${BUILD_DIR}"

orbctl run -m "${MACHINE_NAME}" curl -fsS http://localhost/ >/dev/null
echo "Frontend deployed: http://${MACHINE_NAME}.orb.local/"
