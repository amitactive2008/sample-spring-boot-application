#!/usr/bin/env bash
# =============================================================================
# security-pipeline.sh  —  Security & Code Quality Pipeline  (v4 / Helm + Kind)
# Issue Tracker v4 | Run on the developer machine or CI agent
# =============================================================================
#
# Pipeline steps (README §13):
#   13.1  Gitleaks        — secret scanning
#   13.2  Hadolint        — Dockerfile linting
#   13.3  Helm            — chart lint and render
#   13.4  Trivy config    — Dockerfiles + Helm/Kubernetes configuration
#   13.5  Kubesec         — rendered Deployment security scoring
#   13.6  kube-score      — rendered manifest best-practice analysis
#   13.7  Checkstyle      — Java code style
#   13.8  Semgrep         — SAST (Java + JS/React)
#   13.9  Maven Build     — compile and package all services
#   13.10 NVD Check       — one incremental update, then offline service scans
#   13.11 Lint            — ESLint + SpotBugs
#   13.12 Podman Build    — build container images
#   13.13 Trivy image     — image CVE scan
#   13.14 SonarCloud      — quality and security analysis
#   13.15 Quality Gate    — SonarCloud merge gate
#   13.16 DAST            — OWASP ZAP against the running Kind cluster
#
# Usage:
#   chmod +x security-pipeline.sh
#   ./security-pipeline.sh [OPTIONS]
#
# Options:
#   --skip-nvd        Skip the NVD update, Java dependency scans, and npm audit
#   --skip-sonar      Skip Sonar analysis and Quality Gate
#   --skip-dast       Skip DAST (requires the Kind deployment)
#   --skip-build      Skip Maven and Podman builds; NVD still updates and scans
#   --skip-install    Abort if a tool is missing instead of installing it
#   --nvd-key  KEY    NVD API key for faster dependency scan
#   --nvd-data-dir DIR  Persistent NVD database (default: .security-cache/dependency-check)
#   --sonar-mode MODE   cloud, local, or external (default: cloud)
#   --sonar-host URL    Sonar server URL
#   --sonar-org KEY     SonarCloud organization key
#   --sonar-project-prefix KEY  Prefix for per-service Sonar project keys
#   --app-url  URL    Target URL for DAST (default: https://sample-app.kind.local)
#   --repo     DIR    Repo root (default: current directory)
#
# Examples:
#   # Quick pre-commit check (~2 min)
#   ./security-pipeline.sh --skip-nvd --skip-sonar --skip-dast --skip-build
#
#   # Full pipeline with NVD key
#   ./security-pipeline.sh --nvd-key $NVD_API_KEY
#
#   # SonarCloud + incremental NVD update, without DAST
#   SONAR_MODE=cloud SONAR_TOKEN=... NVD_API_KEY=... \
#     ./security-pipeline.sh --skip-dast
# =============================================================================
set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
REPO_DIR="${REPO_DIR:-$(pwd)}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_DIR="${SECURITY_REPORT_DIR:-}"
NVD_API_KEY="${NVD_API_KEY:-}"
NVD_DATA_DIR="${NVD_DATA_DIR:-}"
NVD_PLUGIN_VERSION="${NVD_PLUGIN_VERSION:-12.2.2}"
NVD_FAIL_CVSS="${NVD_FAIL_CVSS:-7}"
APP_URL="${APP_URL:-https://sample-app.kind.local}"
SKIP_NVD="${SKIP_NVD:-false}"
SKIP_SONAR=false
SKIP_DAST=false
SKIP_BUILD=false
SKIP_INSTALL=false
SONAR_MODE="${SONAR_MODE:-cloud}"
SONAR_HOST_URL="${SONAR_HOST_URL:-${SONAR_HOST:-}}"
SONAR_ORGANIZATION="${SONAR_ORGANIZATION:-amitactive2008}"
SONAR_PROJECT_KEY_PREFIX="${SONAR_PROJECT_KEY_PREFIX:-amitactive2008_sample-spring-boot-application}"
SONAR_REGION="${SONAR_REGION:-}"
SONAR_TOKEN="${SONAR_TOKEN:-}"
HELM_CHART_DIR=""
HELM_RENDERED=""

# Images built with Podman (localhost/ prefix is required — see README §6.3)
IMAGES=(
  "localhost/api-gateway:local"
  "localhost/auth-service:local"
  "localhost/issue-service:local"
  "localhost/frontend-service:local"
)

# Minimum acceptable kubesec score (0 = no critical negatives; raise after hardening)
KUBESEC_MIN_SCORE=0
KUBESEC_IMAGE="docker.io/kubesec/kubesec:v2"

# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-nvd)     SKIP_NVD=true;       shift ;;
        --skip-sonar)   SKIP_SONAR=true;     shift ;;
        --skip-dast)    SKIP_DAST=true;      shift ;;
        --skip-build)   SKIP_BUILD=true;     shift ;;
        --skip-install) SKIP_INSTALL=true;   shift ;;
        --nvd-key)      [[ $# -ge 2 ]] || { echo "--nvd-key requires a value" >&2; exit 2; }; NVD_API_KEY="$2"; shift 2 ;;
        --nvd-data-dir) [[ $# -ge 2 ]] || { echo "--nvd-data-dir requires a value" >&2; exit 2; }; NVD_DATA_DIR="$2"; shift 2 ;;
        --sonar-mode)   [[ $# -ge 2 ]] || { echo "--sonar-mode requires a value" >&2; exit 2; }; SONAR_MODE="$2"; shift 2 ;;
        --sonar-host)   [[ $# -ge 2 ]] || { echo "--sonar-host requires a value" >&2; exit 2; }; SONAR_HOST_URL="$2"; shift 2 ;;
        --sonar-org)    [[ $# -ge 2 ]] || { echo "--sonar-org requires a value" >&2; exit 2; }; SONAR_ORGANIZATION="$2"; shift 2 ;;
        --sonar-project-prefix) [[ $# -ge 2 ]] || { echo "--sonar-project-prefix requires a value" >&2; exit 2; }; SONAR_PROJECT_KEY_PREFIX="$2"; shift 2 ;;
        --app-url)      [[ $# -ge 2 ]] || { echo "--app-url requires a value" >&2; exit 2; }; APP_URL="$2"; shift 2 ;;
        --repo)         [[ $# -ge 2 ]] || { echo "--repo requires a value" >&2; exit 2; }; REPO_DIR="$2"; shift 2 ;;
        -h|--help)      sed -n '2,72p' "$0"; exit 0 ;;
        *)              echo "Unknown option: $1"; exit 1 ;;
    esac
done

REPORT_DIR="${REPORT_DIR:-${REPO_DIR}/security-reports/${TIMESTAMP}}"
NVD_DATA_DIR="${NVD_DATA_DIR:-${REPO_DIR}/.security-cache/dependency-check}"
HELM_CHART_DIR="${REPO_DIR}/helm/issue-tracker"
HELM_RENDERED="${REPORT_DIR}/helm-rendered.yaml"

case "$SONAR_MODE" in
    local)    SONAR_HOST_URL="${SONAR_HOST_URL:-http://localhost:9000}" ;;
    cloud)    SONAR_HOST_URL="${SONAR_HOST_URL:-https://sonarcloud.io}" ;;
    external) [[ -n "$SONAR_HOST_URL" ]] || { echo "SONAR_HOST_URL is required for external mode" >&2; exit 2; } ;;
    *) echo "Invalid SONAR_MODE: ${SONAR_MODE} (expected cloud, local, or external)" >&2; exit 2 ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# COLORS
# ─────────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
    BLUE='\033[0;34m' CYAN='\033[0;36m' BOLD='\033[1m' DIM='\033[2m' NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP TRACKING
# ─────────────────────────────────────────────────────────────────────────────
STEP_IDS=(   gitleaks  hadolint  helm    trivy_config  kubesec  kube_score  checkstyle semgrep build   nvd     lint    podman_build trivy_image sonar   gate    dast    )
STEP_NUMS=(  "13.1"   "13.2"    "13.3" "13.4"       "13.5"  "13.6"      "13.7"    "13.8"  "13.9" "13.10" "13.11" "13.12"      "13.13"    "13.14" "13.15" "13.16" )
STEP_NAMES=(
    "Gitleaks          Secret Scanning"
    "Hadolint          Dockerfile Lint"
    "Helm              Lint + Render"
    "Trivy Config      Dockerfiles + Helm/K8s"
    "Kubesec           K8s Manifest Scoring"
    "kube-score        K8s Best-Practice"
    "Checkstyle        Java Code Style"
    "Semgrep           SAST"
    "Maven Build       Compile & Package"
    "NVD Check         Dependency CVEs"
    "Lint              ESLint + SpotBugs"
    "Podman Build      Container Images"
    "Trivy Image       Image CVE Scan"
    "Sonar             Quality Analysis"
    "Quality Gate      Merge/Deploy Gate"
    "DAST              ZAP vs Kind Cluster"
)
STEP_STATUS=(  "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" )
STEP_ELAPSED=( "0" "0" "0" "0" "0" "0" "0" "0" "0" "0" "0" "0" "0" "0" "0" "0" )

PIPELINE_START=$(date +%s)
MAIN_LOG=""

step_index() {
    local id="$1" i
    for i in "${!STEP_IDS[@]}"; do
        [[ "${STEP_IDS[$i]}" == "$id" ]] && echo "$i" && return
    done; echo "-1"
}
set_status()  { local i; i=$(step_index "$1"); [[ $i -ge 0 ]] && STEP_STATUS[$i]="$2"; }
set_elapsed() { local i; i=$(step_index "$1"); [[ $i -ge 0 ]] && STEP_ELAPSED[$i]="$2"; }
get_status()  { local i; i=$(step_index "$1"); [[ $i -ge 0 ]] && echo "${STEP_STATUS[$i]}" || echo "-"; }

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────────────────────
_log() { [[ -n "$MAIN_LOG" ]] && echo "$*" >> "$MAIN_LOG"; }
log_banner() {
    echo ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    printf "${BOLD}${BLUE}║  %-56s  ║${NC}\n" "$1"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"; echo ""
    _log "=== $1 ==="
}
log_step_hdr() {
    echo ""; echo -e "${CYAN}${BOLD}┌─[$1]─ $2 ────────────────────────────────────────────${NC}"; _log "--- [$1] $2 ---"
}
log_info()  { echo -e "  ${BLUE}→${NC}  $*"; _log "INFO: $*"; }
log_ok()    { echo -e "  ${GREEN}✔${NC}  $*"; _log " OK : $*"; }
log_warn()  { echo -e "  ${YELLOW}⚠${NC}  $*"; _log "WARN: $*"; }
log_error() { echo -e "  ${RED}✖${NC}  $*"; _log " ERR: $*"; }

run_step() {
    local id="$1"
    local i; i=$(step_index "$id")
    local num="${STEP_NUMS[$i]}" name="${STEP_NAMES[$i]}"
    local logfile="${REPORT_DIR}/${id}.log" fn="step_${id}"
    local start end elapsed rc

    log_step_hdr "$num" "$name"
    start=$(date +%s)
    "$fn" > >(tee -a "$logfile") 2>&1; rc=$?
    end=$(date +%s); elapsed=$(( end - start ))
    set_elapsed "$id" "$elapsed"

    if [[ $rc -eq 0 ]]; then
        set_status "$id" "PASS"
        echo -e "  ${GREEN}${BOLD}└─ PASSED${NC} (${elapsed}s)"
    else
        set_status "$id" "FAIL"
        echo -e "  ${RED}${BOLD}└─ FAILED${NC} (${elapsed}s)  log: ${logfile}"
    fi
    return $rc
}

skip_step() {
    local id="$1" reason="$2"
    local i; i=$(step_index "$id")
    log_warn "${STEP_NUMS[$i]} ${STEP_NAMES[$i]}: SKIPPED — $reason"
    set_status "$id" "SKIP"
}

# ─────────────────────────────────────────────────────────────────────────────
# SETUP
# ─────────────────────────────────────────────────────────────────────────────
install_if_missing() {
    local name="$1" check="$2" install_cmd="$3"
    if eval "$check" &>/dev/null; then log_ok "$name: ready"; return 0; fi
    if [[ "$SKIP_INSTALL" == "true" ]]; then log_error "$name: not found (--skip-install)"; return 1; fi
    log_info "Installing $name..."
    eval "$install_cmd" 2>&1 | tail -5
    eval "$check" &>/dev/null && log_ok "$name: installed" || { log_error "$name: install failed"; return 1; }
}

mvnw() {
    local svc="$1"; shift
    "${REPO_DIR}/${svc}/mvnw" -f "${REPO_DIR}/${svc}/pom.xml" "$@"
}

sonar_project_key() {
    local svc="$1"
    if [[ "$SONAR_MODE" == "local" ]]; then
        echo "${SONAR_PROJECT_KEY_PREFIX}-${svc}"
    else
        echo "${SONAR_PROJECT_KEY_PREFIX}_${svc}"
    fi
}

setup_tools() {
    log_banner "Setup — checking tools"
    mkdir -p "$REPORT_DIR"
    chmod 0700 "$REPORT_DIR"
    MAIN_LOG="${REPORT_DIR}/pipeline.log"
    touch "$MAIN_LOG"
    echo "Started:    $(date)"        >> "$MAIN_LOG"
    echo "Repository: ${REPO_DIR}"    >> "$MAIN_LOG"
    echo "App URL:    ${APP_URL}"     >> "$MAIN_LOG"
    echo "Reports:    ${REPORT_DIR}"  >> "$MAIN_LOG"

    log_info "Repository : ${REPO_DIR}"
    log_info "App URL    : ${APP_URL}"
    log_info "Reports    : ${REPORT_DIR}"

    local setup_failed=0
    install_if_missing "gitleaks" "command -v gitleaks" \
        'GL=$(curl -sf https://api.github.com/repos/gitleaks/gitleaks/releases/latest | python3 -c "import sys,json;print(json.load(sys.stdin)[\"tag_name\"].lstrip(\"v\"))")
         curl -sSL "https://github.com/gitleaks/gitleaks/releases/download/v${GL}/gitleaks_${GL}_$(uname -s | tr A-Z a-z)_x64.tar.gz" \
           | tar -xz -C /usr/local/bin gitleaks' || setup_failed=1
    install_if_missing "hadolint"   "command -v hadolint"   "brew install hadolint" || setup_failed=1
    install_if_missing "trivy"      "command -v trivy"      "brew install trivy" || setup_failed=1
    install_if_missing "semgrep"    "command -v semgrep"    "pip3 install semgrep --quiet" || setup_failed=1
    install_if_missing "helm"       "command -v helm"       "brew install helm" || setup_failed=1
    install_if_missing "kube-score" "command -v kube-score" "brew install kube-score" || setup_failed=1
    install_if_missing "jq"         "command -v jq"         "brew install jq" || setup_failed=1
    install_if_missing "node/npm"   "command -v npm"        "brew install node" || setup_failed=1

    if ! command -v podman &>/dev/null; then
        log_error "podman: not found — install with: brew install podman"
        setup_failed=1
    else
        log_ok "podman: $(podman --version)"
    fi

    [[ $setup_failed -eq 0 ]] || { log_error "One or more required tools are unavailable"; return 1; }
    log_ok "All tools ready"
}

# ─────────────────────────────────────────────────────────────────────────────
# 13.1  GITLEAKS
# ─────────────────────────────────────────────────────────────────────────────
step_gitleaks() {
    local report="${REPORT_DIR}/gitleaks.json"
    cat > "${REPORT_DIR}/.gitleaks.toml" << 'TOML'
title = "Issue Tracker v4 Gitleaks"
[allowlist]
description = "Placeholder values in docs / kind secrets / .env.example"
regexes = [
    "ReplaceThisWithASecureSecretKeyOfAtLeast32Chars",
    "local-kind-jwt-secret-key-32bytes!!",
    "local-dev-jwt-secret-key-32bytes!!",
    "not-configured", "devpassword123", "rootpassword",
    "StrongPass@2024!", "Admin@2024!", "Admin1234!",
    "squ_xxxxxxxxxxxxxxxxxxxxx"
]
TOML

    log_info "Scanning full git history for secrets..."
    if gitleaks detect \
        --source    "$REPO_DIR" \
        --config    "${REPORT_DIR}/.gitleaks.toml" \
        --report-format json \
        --report-path   "$report" \
        --no-banner --verbose 2>&1; then
        log_ok "No secrets detected"
    else
        local n; n=$(jq 'length' "$report" 2>/dev/null || echo "?")
        log_error "${n} secret(s) found — review ${report}"
        jq -r '.[] | "  \(.RuleID)  \(.File):\(.StartLine)"' "$report" 2>/dev/null || true
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 13.2  HADOLINT
# ─────────────────────────────────────────────────────────────────────────────
step_hadolint() {
    local failed=0
    # DL3007: unpinned :latest — accepted for local dev images
    # DL3002: last USER not root — fixed in Dockerfiles (appuser added)
    local ignore="--ignore DL3007"

    log_info "Linting all Dockerfiles..."
    while IFS= read -r df; do
        log_info "  $df"
        # shellcheck disable=SC2086
        if hadolint $ignore "$df" 2>&1; then
            log_ok "  $(basename "$(dirname "$df")")/Dockerfile: OK"
        else
            log_warn "  $(basename "$(dirname "$df")")/Dockerfile: violations"
            failed=$(( failed + 1 ))
        fi
    done < <(find "$REPO_DIR" -name "Dockerfile" \
               -not -path "*/target/*" \
               -not -path "*/node_modules/*" \
               -not -path "*/security-reports/*" \
               -not -path "*/.security-cache/*" \
               -not -path "*/.git/*")
    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 13.3  HELM LINT + RENDER
# ─────────────────────────────────────────────────────────────────────────────
step_helm() {
    [[ -d "$HELM_CHART_DIR" ]] || { log_error "Helm chart not found: $HELM_CHART_DIR"; return 1; }
    log_info "Linting Helm chart..."
    helm lint "$HELM_CHART_DIR" || return 1
    log_info "Rendering Helm chart for security scanners..."
    helm template issue-tracker "$HELM_CHART_DIR" \
        --namespace issue-app \
        --set global.imagePullPolicy=Never > "$HELM_RENDERED"
    [[ -s "$HELM_RENDERED" ]] || { log_error "Helm rendered an empty manifest"; return 1; }
    log_ok "Rendered manifest: $HELM_RENDERED"
}

# ─────────────────────────────────────────────────────────────────────────────
# 13.4  TRIVY CONFIG
# ─────────────────────────────────────────────────────────────────────────────
step_trivy_config() {
    local report="${REPORT_DIR}/trivy-config.json"

    log_info "Trivy config scan — Dockerfiles + Helm/Kubernetes configuration..."
    # --misconfiguration-scanners includes dockerfile AND kubernetes KSV rules
    if trivy config \
        --exit-code 1 \
        --severity  HIGH,CRITICAL \
        --format    json \
        --output    "$report" \
        --skip-dirs "${REPO_DIR}/frontend-service/node_modules" \
        --skip-dirs "${REPO_DIR}/security-reports" \
        --skip-dirs "${REPO_DIR}/.security-cache" \
        --skip-dirs "${REPO_DIR}/.verify" \
        "$REPO_DIR" 2>&1; then
        log_ok "No HIGH/CRITICAL misconfigurations"
    else
        local dc_n k8s_n
        dc_n=$(jq '[.Results[]? | select(.Target|test("Dockerfile|compose")) | .Misconfigurations[]? | select(.Severity=="HIGH" or .Severity=="CRITICAL")] | length' "$report" 2>/dev/null || echo "?")
        k8s_n=$(jq '[.Results[]? | select(.Target|test("\\.yaml|\\.yml")) | .Misconfigurations[]? | select(.Severity=="HIGH" or .Severity=="CRITICAL")] | length' "$report" 2>/dev/null || echo "?")
        log_error "Dockerfile/Compose: $dc_n  |  Kubernetes YAML: $k8s_n  HIGH/CRITICAL finding(s)"
        log_error "Review: ${report}"
        # Print inline summary
        jq -r '.Results[]? | .Target as $t | .Misconfigurations[]?
               | select(.Severity=="HIGH" or .Severity=="CRITICAL")
               | "  [\(.Severity)] \($t): \(.ID) — \(.Title)"' \
            "$report" 2>/dev/null | sort -u | head -20 || true
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 13.5  KUBESEC — local scan of rendered Deployment resources
# ─────────────────────────────────────────────────────────────────────────────
step_kubesec() {
    local report="${REPORT_DIR}/kubesec.json"
    local manifest_dir="${REPORT_DIR}/kubesec-manifests"
    local failed=0 total=0
    [[ -s "$HELM_RENDERED" ]] || { log_error "Rendered Helm manifest is missing; Helm step must pass first"; return 1; }
    mkdir -p "$manifest_dir"

    awk -v dir="$manifest_dir" '
        BEGIN { n=1; out=sprintf("%s/doc-%03d.yaml", dir, n) }
        /^---[[:space:]]*$/ { close(out); n++; out=sprintf("%s/doc-%03d.yaml", dir, n); next }
        { print > out }
    ' "$HELM_RENDERED"

    echo "[]" > "$report"
    while IFS= read -r manifest; do
        grep -q '^kind: Deployment[[:space:]]*$' "$manifest" || continue
        local result score name combined
        result=$(podman run --rm --platform linux/amd64 \
            -v "${manifest_dir}:/manifests:ro" \
            "$KUBESEC_IMAGE" \
            scan "/manifests/$(basename "$manifest")" 2>/dev/null) || result='[]'
        score=$(printf '%s' "$result" | jq -r '.[0].score // -999')
        name=$(printf '%s' "$result" | jq -r '.[0].object // "unknown"')
        total=$(( total + 1 ))
        combined=$(jq -s '.[0] + [.[1][0]]' "$report" <(printf '%s' "$result"))
        printf '%s\n' "$combined" > "$report"
        if [[ "$score" -ge "$KUBESEC_MIN_SCORE" ]]; then
            log_ok "$name: score=$score"
        else
            log_error "$name: score=$score (minimum $KUBESEC_MIN_SCORE)"
            failed=$(( failed + 1 ))
        fi
    done < <(find "$manifest_dir" -type f -name '*.yaml' | sort)

    [[ $total -gt 0 ]] || { log_error "No rendered Deployment manifests were scanned"; return 1; }
    log_info "$total Deployment manifest(s) scanned; report: $report"
    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 13.6  KUBE-SCORE
# ─────────────────────────────────────────────────────────────────────────────
step_kube_score() {
    local report="${REPORT_DIR}/kube-score.txt"

    log_info "Running kube-score on rendered manifests..."
    # --ignore-test: ImagePullPolicy=Never is intentional for local kind dev
    kube-score score "$HELM_RENDERED" \
        --output-format ci \
        --ignore-test container-image-pull-policy \
        2>&1 | tee "$report"

    local critical_count
    critical_count=$(grep -c "^\[CRITICAL\]" "$report" 2>/dev/null || true)
    critical_count="${critical_count:-0}"
    local warning_count
    warning_count=$(grep -c "^\[WARNING\]" "$report" 2>/dev/null || true)
    warning_count="${warning_count:-0}"

    log_info "CRITICAL: $critical_count  |  WARNING: $warning_count"
    log_info "Full report: $report"

    if [[ "$critical_count" -gt 0 ]]; then
        log_error "$critical_count CRITICAL finding(s) — see README §13.6 for recommended fixes"
        return 1
    else
        log_ok "No CRITICAL kube-score findings"
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 13.7  CHECKSTYLE
# ─────────────────────────────────────────────────────────────────────────────
step_checkstyle() {
    local cs_xml="${REPORT_DIR}/checkstyle.xml"
    cat > "$cs_xml" << 'XML'
<?xml version="1.0"?>
<!DOCTYPE module PUBLIC "-//Checkstyle//DTD Checkstyle Configuration 1.3//EN"
    "https://checkstyle.org/dtds/configuration_1_3.dtd">
<module name="Checker">
    <property name="charset" value="UTF-8"/>
    <property name="severity" value="warning"/>
    <module name="NewlineAtEndOfFile"><property name="lineSeparator" value="lf"/></module>
    <module name="TreeWalker">
        <module name="TypeName"/>
        <module name="ConstantName"/>
        <module name="MethodName"/>
        <module name="PackageName"/>
        <module name="LocalVariableName"/>
        <module name="ParameterName"/>
        <module name="AvoidStarImport">
            <property name="excludes" value="lombok,lombok.extern.slf4j"/>
        </module>
        <module name="UnusedImports"/>
        <module name="IllegalImport"><property name="illegalPkgs" value="sun"/></module>
        <module name="NeedBraces"/>
        <module name="EmptyBlock"/>
        <module name="EqualsHashCode"/>
        <module name="SimplifyBooleanExpression"/>
        <module name="SimplifyBooleanReturn"/>
        <module name="StringLiteralEquality"/>
        <module name="FallThrough"/>
        <module name="UpperEll"/>
    </module>
</module>
XML

    local plugin="org.apache.maven.plugins:maven-checkstyle-plugin:3.3.1:check"
    local failed=0
    for svc in auth-service issue-service api-gateway; do
        log_info "Checkstyle: $svc"
        if mvnw "$svc" "$plugin" \
            "-Dcheckstyle.config.location=${cs_xml}" \
            -Dcheckstyle.consoleOutput=true \
            -Dcheckstyle.failsOnError=true \
            -B --no-transfer-progress 2>&1; then
            log_ok "$svc: style OK"
        else
            log_warn "$svc: style violations"; failed=$(( failed + 1 ))
        fi
    done
    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 13.8  SEMGREP
# ─────────────────────────────────────────────────────────────────────────────
step_semgrep() {
    local out_java="${REPORT_DIR}/semgrep-java.json"
    local out_js="${REPORT_DIR}/semgrep-js.json"

    log_info "SAST — Java (spring-security, java, owasp-top-ten)..."
    semgrep scan \
        --config "p/spring-security" --config "p/java" --config "p/owasp-top-ten" \
        --json --output "$out_java" --quiet \
        "${REPO_DIR}/auth-service/src" \
        "${REPO_DIR}/issue-service/src" \
        "${REPO_DIR}/api-gateway/src" 2>&1 || true

    log_info "SAST — React/JS (javascript, react)..."
    semgrep scan \
        --config "p/javascript" --config "p/react" \
        --json --output "$out_js" --quiet \
        "${REPO_DIR}/frontend-service/src" 2>&1 || true

    local java_err js_err
    java_err=$(jq '[.results[]|select(.extra.severity=="ERROR")]|length' "$out_java" 2>/dev/null || echo 0)
    js_err=$(jq   '[.results[]|select(.extra.severity=="ERROR")]|length' "$out_js"   2>/dev/null || echo 0)
    local total_err=$(( java_err + js_err ))
    local total=$(( $(jq '.results|length' "$out_java" 2>/dev/null||echo 0) + $(jq '.results|length' "$out_js" 2>/dev/null||echo 0) ))

    log_info "Findings — Java: $(jq '.results|length' "$out_java" 2>/dev/null||echo 0) | JS: $(jq '.results|length' "$out_js" 2>/dev/null||echo 0) | ERROR-level: $total_err"
    if [[ $total_err -gt 0 ]]; then
        log_error "$total_err high-severity finding(s):"
        jq -r '.results[]|select(.extra.severity=="ERROR")|"  [\(.check_id)] \(.path):\(.start.line)"' \
            "$out_java" "$out_js" 2>/dev/null | head -10 || true
        return 1
    fi
    [[ $total -eq 0 ]] && log_ok "No SAST findings" || log_warn "$total informational finding(s) — review reports"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 13.9  MAVEN BUILD
# ─────────────────────────────────────────────────────────────────────────────
step_build() {
    local failed=0
    for svc in auth-service issue-service api-gateway; do
        log_info "Building $svc..."
        if mvnw "$svc" clean package -DskipTests -B --no-transfer-progress 2>&1; then
            local jar; jar=$(find "${REPO_DIR}/${svc}/target" -name "*.jar" \
                ! -name "*sources*" ! -name "*javadoc*" ! -name "*.original" 2>/dev/null | head -1)
            log_ok "$svc → ${jar##*/}"
        else
            log_error "$svc: BUILD FAILED"; failed=$(( failed + 1 ))
        fi
    done
    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 13.10  NVD CHECK
# ─────────────────────────────────────────────────────────────────────────────
step_nvd() {
    local plugin="org.owasp:dependency-check-maven:${NVD_PLUGIN_VERSION}"
    local failed=0
    local nvd_report_dir="${REPORT_DIR}/nvd"
    mkdir -p "$NVD_DATA_DIR" "$nvd_report_dir"
    chmod 0700 "$NVD_DATA_DIR"

    if [[ -z "$NVD_API_KEY" ]]; then
        log_warn "NVD_API_KEY not set — NVD updates may be heavily rate-limited"
        log_warn "Set: export NVD_API_KEY=... (free key at nvd.nist.gov/developers/request-an-api-key)"
    fi

    local update_args=(
        "${plugin}:update-only"
        "-DdataDirectory=${NVD_DATA_DIR}"
        -DversionCheckEnabled=false
        -B
        --no-transfer-progress
    )
    if [[ -n "$NVD_API_KEY" ]]; then
        export ODC_NVD_API_KEY="$NVD_API_KEY"
        update_args+=("-DnvdApiKeyEnvironmentVariable=ODC_NVD_API_KEY")
    fi

    log_info "Incrementally updating shared NVD database: $NVD_DATA_DIR"
    if mvnw auth-service "${update_args[@]}" 2>&1; then
        date -u +'%Y-%m-%dT%H:%M:%SZ' > "${NVD_DATA_DIR}/last-successful-update.txt"
        log_ok "NVD database update completed"
    else
        log_error "NVD database update failed; service scans were not run"
        return 1
    fi

    for svc in auth-service issue-service api-gateway; do
        local service_report_dir="${nvd_report_dir}/${svc}"
        mkdir -p "$service_report_dir"
        log_info "NVD scan from refreshed local database: $svc..."
        if mvnw "$svc" "${plugin}:check" \
            "-DdataDirectory=${NVD_DATA_DIR}" \
            -DautoUpdate=false \
            -DversionCheckEnabled=false \
            -DskipTestScope=true \
            "-DfailBuildOnCVSS=${NVD_FAIL_CVSS}" \
            -Dformats=HTML,JSON \
            "-Dodc.outputDirectory=${service_report_dir}" \
            -B --no-transfer-progress 2>&1; then
            log_ok "$svc: no CVSS≥${NVD_FAIL_CVSS} vulnerabilities"
        else
            log_error "$svc: scan failed or found CVSS≥${NVD_FAIL_CVSS} vulnerabilities — ${service_report_dir}"
            failed=$(( failed + 1 ))
        fi
    done

    if command -v npm &>/dev/null && [[ -d "${REPO_DIR}/frontend-service" ]]; then
        log_info "npm audit — frontend..."
        cd "${REPO_DIR}/frontend-service"
        [[ -d node_modules ]] || npm ci --silent
        local npm_report="${nvd_report_dir}/npm-audit.json"
        if npm audit --audit-level=high --json > "$npm_report"; then
            log_ok "frontend: npm audit clean"
        else
            local high critical
            high=$(jq -r '.metadata.vulnerabilities.high // 0' "$npm_report" 2>/dev/null || echo 0)
            critical=$(jq -r '.metadata.vulnerabilities.critical // 0' "$npm_report" 2>/dev/null || echo 0)
            log_error "frontend: high=$high critical=$critical — $npm_report"
            failed=$(( failed + 1 ))
        fi
        cd - > /dev/null
    fi
    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 13.11  LINT  (ESLint + SpotBugs)
# ─────────────────────────────────────────────────────────────────────────────
step_lint() {
    local failed=0
    log_info "ESLint — frontend..."
    cd "${REPO_DIR}/frontend-service"
    [[ ! -d node_modules ]] && npm install --silent 2>&1 | tail -3
    if npm run lint 2>&1; then log_ok "ESLint: passed"
    else log_error "ESLint: violations"; failed=$(( failed + 1 )); fi
    cd - > /dev/null

    local sb="com.github.spotbugs:spotbugs-maven-plugin:4.8.3.1:check"
    for svc in auth-service issue-service api-gateway; do
        if [[ ! -d "${REPO_DIR}/${svc}/target/classes" ]]; then
            log_warn "$svc: no compiled classes — run Maven Build first"; continue
        fi
        log_info "SpotBugs: $svc..."
        if mvnw "$svc" "$sb" \
            -Dspotbugs.effort=Max -Dspotbugs.threshold=Low -Dspotbugs.failOnError=true \
            -B --no-transfer-progress 2>&1; then
            log_ok "$svc: SpotBugs OK"
        else
            log_warn "$svc: SpotBugs findings"; failed=$(( failed + 1 ))
        fi
    done
    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 13.12  PODMAN BUILD
# ─────────────────────────────────────────────────────────────────────────────
step_podman_build() {
    log_info "Building container images with Podman (localhost/ prefix)..."
    cd "$REPO_DIR"
    for svc in api-gateway auth-service issue-service frontend-service; do
        log_info "  podman build localhost/${svc}:local"
        if podman build -t "localhost/${svc}:local" "./${svc}" 2>&1; then
            local size; size=$(podman image inspect "localhost/${svc}:local" \
                --format "{{.Size}}" 2>/dev/null | numfmt --to=iec 2>/dev/null || echo "?")
            log_ok "  localhost/${svc}:local (${size})"
        else
            log_error "  localhost/${svc}:local: BUILD FAILED"
            cd - > /dev/null; return 1
        fi
    done
    cd - > /dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# 13.13  TRIVY IMAGE SCAN
# ─────────────────────────────────────────────────────────────────────────────
step_trivy_image() {
    local failed=0
    local podman_socket=""
    podman_socket=$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' \
        2>/dev/null | head -1 || true)
    if [[ -z "$podman_socket" || ! -S "$podman_socket" ]]; then
        podman_socket=$(podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null \
            | sed 's#^unix://##' || true)
    fi

    for img in "${IMAGES[@]}"; do
        local svc_name; svc_name="${img##*/}"; svc_name="${svc_name%%:*}"
        local img_report="${REPORT_DIR}/trivy-image-${svc_name}.json"

        if ! podman image exists "$img" 2>/dev/null; then
            log_warn "Image $img not found — run Podman Build first"
            continue
        fi
        log_info "Scanning image: $img..."
        local scan_rc=0 archive=""
        if [[ -n "$podman_socket" && -S "$podman_socket" ]]; then
            trivy image \
                --image-src podman \
                --podman-host "$podman_socket" \
                --scanners vuln \
                --exit-code 1 \
                --severity HIGH,CRITICAL \
                --format json \
                --output "$img_report" \
                "$img" 2>&1 || scan_rc=$?
        else
            archive=$(mktemp -t "trivy-${svc_name}") || return 1
            if podman save --format docker-archive -o "$archive" "$img" 2>&1; then
                trivy image \
                    --scanners vuln \
                    --exit-code 1 \
                    --severity HIGH,CRITICAL \
                    --format json \
                    --output "$img_report" \
                    --input "$archive" 2>&1 || scan_rc=$?
            else
                scan_rc=2
            fi
        fi

        if [[ $scan_rc -eq 0 ]]; then
            log_ok "$svc_name: no HIGH/CRITICAL CVEs"
        elif jq -e '.Results | type == "array"' "$img_report" &>/dev/null; then
            local n; n=$(jq '[.Results[]?.Vulnerabilities[]?|select(.Severity=="HIGH" or .Severity=="CRITICAL")]|length' \
                "$img_report" 2>/dev/null || echo "?")
            log_error "$svc_name: $n HIGH/CRITICAL CVE(s) — $img_report"
            jq -r '.Results[]?.Vulnerabilities[]?|select(.Severity=="HIGH" or .Severity=="CRITICAL")|"    \(.Severity)  \(.VulnerabilityID)  \(.PkgName) \(.InstalledVersion) → \(.FixedVersion//"no fix")"' \
                "$img_report" 2>/dev/null | sort -u | head -5 || true
            failed=$(( failed + 1 ))
        else
            log_error "$svc_name: Trivy could not read or analyse the Podman image"
            failed=$(( failed + 1 ))
        fi
        [[ -n "$archive" ]] && rm -f "$archive"
    done
    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 13.14  SONAR
# ─────────────────────────────────────────────────────────────────────────────
step_sonar() {
    [[ -n "$SONAR_TOKEN" ]] || { log_error "SONAR_TOKEN is required for $SONAR_MODE mode"; return 1; }
    [[ -n "$SONAR_PROJECT_KEY_PREFIX" ]] || { log_error "SONAR_PROJECT_KEY_PREFIX is required"; return 1; }
    if [[ "$SONAR_MODE" == "cloud" && -z "$SONAR_ORGANIZATION" ]]; then
        log_error "SONAR_ORGANIZATION is required for cloud mode"; return 1
    fi

    export SONAR_TOKEN
    log_info "Using ${SONAR_MODE} analysis at ${SONAR_HOST_URL}; credentials remain in process environment"

    local failed=0 svc key
    for svc in auth-service issue-service api-gateway frontend-service; do
        key=$(sonar_project_key "$svc")
        local sonar_args=("-Dsonar.host.url=${SONAR_HOST_URL}" "-Dsonar.projectKey=${key}")
        [[ -n "$SONAR_ORGANIZATION" ]] && sonar_args+=("-Dsonar.organization=${SONAR_ORGANIZATION}")
        [[ -n "$SONAR_REGION" ]] && sonar_args+=("-Dsonar.region=${SONAR_REGION}")
        log_info "Analysing ${svc} as ${key}..."
        if [[ "$svc" == "frontend-service" ]]; then
            sonar_args+=("-Dsonar.sources=src" "-Dsonar.exclusions=build/**,node_modules/**,.scannerwork/**")
            if (cd "${REPO_DIR}/frontend-service" && npx --yes @sonar/scan@4.3.5 "${sonar_args[@]}" 2>&1); then
                log_ok "$svc: submitted"
            else
                log_error "$svc: analysis failed"; failed=$(( failed + 1 ))
            fi
        elif mvnw "$svc" "org.sonarsource.scanner.maven:sonar-maven-plugin:sonar" \
            "${sonar_args[@]}" -B --no-transfer-progress 2>&1; then
            log_ok "$svc: submitted"
        else
            log_error "$svc: analysis failed"; failed=$(( failed + 1 ))
        fi
    done
    log_info "Dashboard: ${SONAR_HOST_URL}/projects"
    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 13.15  QUALITY GATE
# ─────────────────────────────────────────────────────────────────────────────
step_gate() {
    [[ -n "$SONAR_TOKEN" ]] || { log_error "No Sonar token — did the analysis step pass?"; return 1; }
    local failed=0
    for svc in auth-service issue-service api-gateway frontend-service; do
        local key
        key=$(sonar_project_key "$svc")
        log_info "Quality Gate: $svc..."
        local attempts=0 status=""
        while [[ $attempts -lt 36 ]]; do
            status=$(printf 'Authorization: Bearer %s\n' "$SONAR_TOKEN" | curl -sf -H @- \
                "${SONAR_HOST_URL}/api/qualitygates/project_status?projectKey=${key}" \
                | jq -r '.projectStatus.status' 2>/dev/null || echo "")
            [[ "$status" =~ ^(OK|ERROR|WARN|NONE)$ ]] && break
            sleep 5; attempts=$(( attempts + 1 )); printf "."
        done; echo ""
        case "$status" in
            OK)    log_ok   "$svc: Gate PASSED" ;;
            ERROR) log_error "$svc: Gate FAILED"
                   printf 'Authorization: Bearer %s\n' "$SONAR_TOKEN" | curl -sf -H @- \
                       "${SONAR_HOST_URL}/api/qualitygates/project_status?projectKey=${key}" \
                       | jq -r '.projectStatus.conditions[]|select(.status=="ERROR")|"    \(.metricKey): \(.actualValue) (threshold: \(.errorThreshold))"' \
                       2>/dev/null || true
                   failed=$(( failed + 1 )) ;;
            WARN)  log_warn "$svc: warnings (not blocking)" ;;
            NONE)  log_error "$svc: no quality gate assigned"; failed=$(( failed + 1 )) ;;
            *)     log_error "$svc: quality gate result unavailable"; failed=$(( failed + 1 )) ;;
        esac
    done
    log_info "Dashboard: ${SONAR_HOST_URL}/projects"
    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 13.16  DAST  (ZAP against the running Kind cluster)
# ─────────────────────────────────────────────────────────────────────────────
step_dast() {
    log_info "Checking kind cluster at ${APP_URL}..."
    if ! curl -ksf --max-time 10 "${APP_URL}/" &>/dev/null; then
        log_error "App not reachable at ${APP_URL}"
        log_error "Deploy or check it first: ./scripts/helm-deploy.sh check"
        return 1
    fi
    log_ok "Cluster is reachable"

    local html="${REPORT_DIR}/zap-report.html" json="${REPORT_DIR}/zap-report.json"
    log_info "ZAP baseline scan (passive) — target: ${APP_URL}"

    local app_host
    app_host=$(printf '%s' "$APP_URL" | sed -E 's#^[a-zA-Z]+://([^/:]+).*#\1#')

    local kind_node_ip
    kind_node_ip=$(podman inspect issue-app-control-plane \
        --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}' 2>/dev/null)
    [[ -n "$kind_node_ip" ]] || { log_error "Could not resolve the Kind control-plane IP"; return 1; }

    if podman run --rm \
        --network kind \
        --add-host "${app_host}:${kind_node_ip}" \
        -v "${REPORT_DIR}:/zap/wrk:rw" \
        ghcr.io/zaproxy/zaproxy:stable \
        zap-baseline.py \
            -t "${APP_URL}/" \
            -r "zap-report.html" \
            -J "zap-report.json" \
            -z "-config connection.ssl.acceptAll=true" \
            -l WARN -I 2>&1; then
        log_ok "ZAP scan complete — ${html}"
    else
        local n; n=$(jq '[.site[].alerts[]|select(.riskcode|tonumber>=2)]|length' \
            "$json" 2>/dev/null || echo "?")
        log_error "$n medium/high alert(s) — ${html}"
        jq -r '.site[].alerts[]|select(.riskcode|tonumber>=2)|"  [\(.riskdesc)] \(.alert)"' \
            "$json" 2>/dev/null | sort -u || true
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
print_summary() {
    local end total pass=0 fail=0 skip=0
    end=$(date +%s); total=$(( end - PIPELINE_START ))

    echo ""
    echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║    SECURITY & CODE QUALITY PIPELINE — v4 SUMMARY           ║${NC}"
    echo -e "${BOLD}${BLUE}╠════════════════════════════════════════════════════════════╣${NC}"

    for i in "${!STEP_IDS[@]}"; do
        local status="${STEP_STATUS[$i]}" elapsed="${STEP_ELAPSED[$i]}"
        local color icon
        case "$status" in
            PASS) color=$GREEN;  icon="✔"; pass=$(( pass+1 )) ;;
            FAIL) color=$RED;    icon="✖"; fail=$(( fail+1 )) ;;
            SKIP) color=$YELLOW; icon="—"; skip=$(( skip+1 )) ;;
            *)    color=$DIM;    icon="?"; ;;
        esac
        printf "${BOLD}${BLUE}║${NC}  ${color}${BOLD}%s${NC}  %-6s  %-34s  %5ss  ${BOLD}${BLUE}║${NC}\n" \
            "$icon" "${STEP_NUMS[$i]}" "${STEP_NAMES[$i]}" "$elapsed"
    done

    echo -e "${BOLD}${BLUE}╠════════════════════════════════════════════════════════════╣${NC}"
    local vmsg vcolor
    if [[ $fail -gt 0 ]]; then
        vcolor=$RED; vmsg="${fail} CHECK(S) FAILED — do not merge/deploy"
    elif [[ $skip -gt 0 ]]; then
        vcolor=$YELLOW; vmsg="PARTIAL SCAN — ${skip} CHECK(S) SKIPPED"
    else
        vcolor=$GREEN; vmsg="ALL CHECKS PASSED — safe to merge/deploy"
    fi
    printf "${BOLD}${BLUE}║${NC}  ${vcolor}${BOLD}%-58s${NC}  ${BOLD}${BLUE}║${NC}\n" "$vmsg"
    printf "${BOLD}${BLUE}║${NC}  ${DIM}%-58s${NC}  ${BOLD}${BLUE}║${NC}\n" "Pass:$pass  Fail:$fail  Skip:$skip  Total:${total}s"
    printf "${BOLD}${BLUE}║${NC}  ${DIM}%-58s${NC}  ${BOLD}${BLUE}║${NC}\n" "Reports: $REPORT_DIR"
    echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"; echo ""

    if [[ $fail -gt 0 ]]; then
        echo -e "${BOLD}${RED}Failed steps:${NC}"
        for i in "${!STEP_IDS[@]}"; do
            [[ "${STEP_STATUS[$i]}" == "FAIL" ]] || continue
            echo -e "  ${RED}✖${NC} ${STEP_NUMS[$i]} ${STEP_NAMES[$i]}"
            echo -e "    ${DIM}log: ${REPORT_DIR}/${STEP_IDS[$i]}.log${NC}"
        done; echo ""
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    log_banner "Security & Code Quality Pipeline — Issue Tracker v4 (Helm + Kind)"
    echo -e "  ${DIM}Repository : ${REPO_DIR}${NC}"
    echo -e "  ${DIM}App URL    : ${APP_URL}${NC}"
    echo -e "  ${DIM}Started    : $(date)${NC}"
    [[ "$SKIP_NVD"   == "true" ]] && echo -e "  ${YELLOW}⚠${NC}  NVD + npm audit: SKIPPED"
    [[ "$SKIP_SONAR" == "true" ]] && echo -e "  ${YELLOW}⚠${NC}  SonarQube + Quality Gate: SKIPPED"
    [[ "$SKIP_DAST"  == "true" ]] && echo -e "  ${YELLOW}⚠${NC}  DAST: SKIPPED"
    [[ "$SKIP_BUILD" == "true" ]] && echo -e "  ${YELLOW}⚠${NC}  Maven Build + Podman Build: SKIPPED"
    echo ""

    [[ -d "$REPO_DIR" ]] || { echo "Repo not found: $REPO_DIR"; exit 1; }
    setup_tools || exit 1

    # ── Source + K8s checks (no build needed) ──────────────────────────────
    run_step "gitleaks"
    run_step "hadolint"
    run_step "helm"
    run_step "trivy_config"
    if [[ "$(get_status helm)" == "PASS" ]]; then
        run_step "kubesec"
        run_step "kube_score"
    else
        skip_step "kubesec" "Helm render failed"
        skip_step "kube_score" "Helm render failed"
    fi
    run_step "checkstyle"
    run_step "semgrep"

    # ── Build-dependent steps ───────────────────────────────────────────────
    if [[ "$SKIP_BUILD" == "true" ]]; then
        skip_step "build"        "--skip-build flag"
        skip_step "lint"         "--skip-build flag"
        skip_step "podman_build" "--skip-build flag"
        skip_step "trivy_image"  "--skip-build flag"
    else
        run_step "build"

        local build_ok=false
        [[ "$(get_status build)" == "PASS" ]] && build_ok=true

        if $build_ok; then
            run_step "lint"
            run_step "podman_build"
        else
            skip_step "lint" "Maven Build failed"
            skip_step "podman_build" "Maven Build failed"
        fi

        local images_ok=false
        [[ "$(get_status podman_build)" == "PASS" ]] && images_ok=true
        if $images_ok; then
            run_step "trivy_image"
        else
            skip_step "trivy_image" "Podman Build failed"
        fi
    fi

    # Dependency-Check uses the persistent local database and can scan directly
    # from pom.xml even when Maven and Podman builds are skipped.
    [[ "$SKIP_NVD" == "true" ]] && skip_step "nvd" "--skip-nvd flag" || run_step "nvd"

    # ── SonarQube ───────────────────────────────────────────────────────────
    if [[ "$SKIP_SONAR" == "true" ]]; then
        skip_step "sonar" "--skip-sonar flag"
        skip_step "gate"  "--skip-sonar flag"
    else
        local build_ok=false
        [[ "$(get_status build)" == "PASS" || "$SKIP_BUILD" == "true" ]] && build_ok=true
        if $build_ok; then
            run_step "sonar"
            if [[ "$(get_status sonar)" == "PASS" ]]; then
                run_step "gate"
            else
                skip_step "gate" "Sonar analysis failed"
            fi
        else
            skip_step "sonar" "Maven Build failed"
            skip_step "gate"  "Maven Build failed"
        fi
    fi

    # ── DAST ────────────────────────────────────────────────────────────────
    [[ "$SKIP_DAST" == "true" ]] && skip_step "dast" "--skip-dast flag" || run_step "dast"

    print_summary
}

main "$@"
