#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="scan"
data_directory="${NVD_DATA_DIR:-${repository_root}/.security-cache/dependency-check}"
report_directory="${NVD_REPORT_DIR:-${repository_root}/security-reports/nvd/$(date +%Y%m%d-%H%M%S)}"
plugin_version="${NVD_PLUGIN_VERSION:-12.2.2}"
fail_cvss="${NVD_FAIL_CVSS:-7}"
nvd_api_key="${NVD_API_KEY:-}"
skip_update=false

usage() {
  cat <<'EOF'
Usage: ./scripts/nvd-scan.sh [init|scan] [options]

Modes:
  init                 Download or incrementally update the local NVD database only
  scan                 Update the database once, then scan all Java services (default)

Options:
  --data-dir DIR       Persistent database directory
  --report-dir DIR     Scan report directory
  --nvd-key KEY        NVD API key (prefer the NVD_API_KEY environment variable)
  --plugin-version VER OWASP Dependency-Check Maven plugin version
  --fail-cvss SCORE    Fail a service scan at this CVSS score (default: 7)
  --skip-update        Scan from the existing cache without accessing NVD
  -h, --help           Show this help

Environment equivalents:
  NVD_DATA_DIR, NVD_REPORT_DIR, NVD_API_KEY, NVD_PLUGIN_VERSION, NVD_FAIL_CVSS
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    init|scan) mode="$1"; shift ;;
    --data-dir) data_directory="$2"; shift 2 ;;
    --report-dir) report_directory="$2"; shift 2 ;;
    --nvd-key) nvd_api_key="$2"; shift 2 ;;
    --plugin-version) plugin_version="$2"; shift 2 ;;
    --fail-cvss) fail_cvss="$2"; shift 2 ;;
    --skip-update) skip_update=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$mode" == "init" && "$skip_update" == "true" ]]; then
  echo "init cannot be combined with --skip-update" >&2
  exit 2
fi

mkdir -p "$data_directory"
chmod 0700 "$data_directory"

dependency_check="org.owasp:dependency-check-maven:${plugin_version}"
update_service="${repository_root}/auth-service"

if [[ ! -x "${update_service}/mvnw" ]]; then
  echo "Missing Maven wrapper: ${update_service}/mvnw" >&2
  exit 1
fi

update_database() {
  local update_arguments=(
    "${dependency_check}:update-only"
    "-DdataDirectory=${data_directory}"
    "-DversionCheckEnabled=false"
    -B
    --no-transfer-progress
  )

  if [[ -n "$nvd_api_key" ]]; then
    export ODC_NVD_API_KEY="$nvd_api_key"
    update_arguments+=("-DnvdApiKeyEnvironmentVariable=ODC_NVD_API_KEY")
  else
    echo "Warning: NVD_API_KEY is unset; the initial download may be heavily rate-limited." >&2
  fi

  echo "Updating persistent NVD database: ${data_directory}"
  (cd "$update_service" && ./mvnw "${update_arguments[@]}")
  date -u +'%Y-%m-%dT%H:%M:%SZ' > "${data_directory}/last-successful-update.txt"
  echo "NVD database update completed."
}

if [[ "$skip_update" != "true" ]]; then
  update_database
elif [[ -z "$(find "$data_directory" -type f -name 'odc.mv.db' -print -quit)" ]]; then
  echo "No initialized NVD database found in ${data_directory}. Run '$0 init' first." >&2
  exit 1
fi

if [[ "$mode" == "init" ]]; then
  echo "Initialization complete. Future scans will perform an incremental update first."
  exit 0
fi

mkdir -p "$report_directory"

failed=0
for service in auth-service issue-service api-gateway; do
  service_directory="${repository_root}/${service}"
  service_report_directory="${report_directory}/${service}"
  mkdir -p "$service_report_directory"

  echo "Scanning ${service} with the refreshed local database..."
  if (
    cd "$service_directory"
    ./mvnw \
      "${dependency_check}:check" \
      "-DdataDirectory=${data_directory}" \
      -DautoUpdate=false \
      -DversionCheckEnabled=false \
      -DskipTestScope=true \
      "-DfailBuildOnCVSS=${fail_cvss}" \
      -Dformats=HTML,JSON \
      "-DoutputDirectory=${service_report_directory}" \
      -B \
      --no-transfer-progress
  ); then
    echo "${service}: no vulnerability met the CVSS ${fail_cvss} failure threshold."
  else
    echo "${service}: scan failed or found a vulnerability at CVSS ${fail_cvss} or higher." >&2
    failed=$((failed + 1))
  fi
done

echo "Reports: ${report_directory}"

if [[ $failed -gt 0 ]]; then
  echo "${failed} service scan(s) failed. Review the HTML and JSON reports." >&2
  exit 1
fi

echo "All Java dependency scans passed."
