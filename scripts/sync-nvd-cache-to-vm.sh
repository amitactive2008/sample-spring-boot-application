#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
machine="issue-tracker-v1"
vm_repository="/opt/issue-tracker"

usage() {
  cat <<'EOF'
Usage: ./scripts/sync-nvd-cache-to-vm.sh [options]

Copy the initialized macOS Dependency-Check database into an OrbStack VM.

Options:
  --machine NAME  OrbStack machine name (default: issue-tracker-v1)
  --vm-repo DIR   Repository path inside the VM (default: /opt/issue-tracker)
  -h, --help      Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --machine) machine="$2"; shift 2 ;;
    --vm-repo) vm_repository="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Run this helper from the macOS repository checkout." >&2
  exit 1
fi

if ! command -v orbctl >/dev/null 2>&1; then
  echo "orbctl is not installed or is not on PATH." >&2
  exit 1
fi

local_cache="${repository_root}/.security-cache/dependency-check"
if [[ ! -s "${local_cache}/odc.mv.db" ]]; then
  echo "The local NVD cache is not initialized: ${local_cache}" >&2
  echo "Run './scripts/nvd-scan.sh init' first." >&2
  exit 1
fi

if [[ "$(orbctl status 2>/dev/null || true)" != "Running" ]]; then
  echo "OrbStack is not running. Start OrbStack and the ${machine} VM first." >&2
  exit 1
fi

vm_cache="${vm_repository}/.security-cache/dependency-check"
mac_mount_root="/mnt/mac${repository_root}"
mac_cache="${mac_mount_root}/.security-cache/dependency-check"

if orbctl run -m "$machine" -u root pgrep -f org.owasp.dependencycheck >/dev/null 2>&1; then
  echo "A Dependency-Check process is already running in ${machine}." >&2
  echo "Wait for it to finish before replacing the cache." >&2
  exit 1
fi

echo "Preparing ${machine}:${vm_repository}"
orbctl run -m "$machine" -u root mkdir -p \
  "${vm_repository}/scripts" \
  "$vm_cache"

echo "Syncing current pipeline scripts..."
orbctl run -m "$machine" -u root cp \
  "${mac_mount_root}/security-pipeline.sh" \
  "${vm_repository}/security-pipeline.sh"
orbctl run -m "$machine" -u root cp \
  "${mac_mount_root}/scripts/nvd-scan.sh" \
  "${vm_repository}/scripts/nvd-scan.sh"
orbctl run -m "$machine" -u root chmod +x \
  "${vm_repository}/security-pipeline.sh" \
  "${vm_repository}/scripts/nvd-scan.sh"

echo "Copying the persistent NVD database into the VM..."
orbctl run -m "$machine" -u root cp -a "${mac_cache}/." "${vm_cache}/"
orbctl run -m "$machine" -u root chown -R root:root "$vm_cache"
orbctl run -m "$machine" -u root chmod -R u+rwX,go-rwx "$vm_cache"

if ! orbctl run -m "$machine" -u root test -s "${vm_cache}/odc.mv.db"; then
  echo "The VM cache copy could not be verified." >&2
  exit 1
fi

cache_size=$(orbctl run -m "$machine" -u root du -sh "$vm_cache" | awk '{print $1}')
echo "NVD cache ready in ${machine}: ${vm_cache} (${cache_size})"
echo "The next VM scan will incrementally update this cache before scanning."
echo ""
echo "Run the full pipeline with:"
echo "  ORBENV=NVD_API_KEY orbctl run -m ${machine} -u root -w ${vm_repository} ./security-pipeline.sh"
