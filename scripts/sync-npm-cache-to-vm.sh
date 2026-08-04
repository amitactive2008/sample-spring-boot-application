#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
MACHINE_NAME="${1:-issue-tracker-v1}"
SOURCE_CACHE="${NPM_CACHE_SOURCE:-${HOME}/.npm}"
TARGET_CACHE="/opt/issue-tracker/.security-cache/npm"

command -v orbctl >/dev/null 2>&1 || {
  echo "orbctl is required. Install and start OrbStack first." >&2
  exit 1
}

if [[ ! -d "${SOURCE_CACHE}/_cacache" ]]; then
  echo "npm cache not found at ${SOURCE_CACHE}." >&2
  echo "Run the frontend install or build on the Mac first." >&2
  exit 1
fi

echo "Copying the Mac npm cache to ${MACHINE_NAME}..."
orbctl run -m "${MACHINE_NAME}" sudo bash -c '
  set -euo pipefail
  source_cache="$1"
  target_cache="$2"
  install -d -m 0755 "${target_cache}"
  cp -R "${source_cache}/." "${target_cache}/"
' _ "${SOURCE_CACHE}" "${TARGET_CACHE}"

echo "npm cache ready at ${TARGET_CACHE}"
