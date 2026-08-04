#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
MACHINE_NAME="${1:-issue-tracker-v1}"

command -v orbctl >/dev/null 2>&1 || {
  echo "orbctl is required. Install and start OrbStack first." >&2
  exit 1
}

if orbctl list | awk '{print $1}' | grep -Fxq "${MACHINE_NAME}"; then
  echo "OrbStack machine '${MACHINE_NAME}' already exists." >&2
  echo "Delete it explicitly or choose another name." >&2
  exit 1
fi

orbctl create \
  --cpus 2 \
  --memory 4G \
  --disk 20G \
  --user-data "${REPO_DIR}/cloud-init.yaml" \
  ubuntu:22.04 \
  "${MACHINE_NAME}"

echo "Waiting for cloud-init provisioning..."
if ! orbctl run -m "${MACHINE_NAME}" cloud-init status --wait --long; then
  echo "Provisioning failed. Last setup log lines:" >&2
  orbctl run -m "${MACHINE_NAME}" sudo tail -n 200 /var/log/issue-tracker-setup.log >&2 || true
  exit 1
fi

"${SCRIPT_DIR}/sync-frontend-to-vm.sh" "${MACHINE_NAME}"
"${SCRIPT_DIR}/sync-npm-cache-to-vm.sh" "${MACHINE_NAME}"

echo "VM is ready: http://${MACHINE_NAME}.orb.local/"
