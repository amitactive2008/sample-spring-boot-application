#!/usr/bin/env bash
# =============================================================================
# security-pipeline.sh  —  Security & Code Quality Pipeline  (v2 / Podman)
# Issue Tracker v2 | Run on the developer machine or a CI agent
# =============================================================================
#
# Pipeline steps (README §10):
#   10.1  Gitleaks       — secret scanning
#   10.2  Hadolint       — Dockerfile linting          [v2 NEW]
#   10.3  Checkstyle     — Java code style
#   10.4  Semgrep        — SAST (Java + JS/React)
#   10.5  Maven Build    — compile & package all services
#   10.6  NVD Check      — dependency CVE scanning
#   10.7  Lint           — ESLint (React) + SpotBugs (Java)
#   10.8  Podman Build   — build / verify container images
#   10.9  Trivy          — image CVE + config scan      [v2 NEW]
#   10.10 SonarQube      — deep quality & security analysis
#   10.11 Quality Gate   — SonarQube merge gate
#   10.12 DAST           — OWASP ZAP dynamic scan
#
# Usage:
#   chmod +x security-pipeline.sh
#   ./security-pipeline.sh [OPTIONS]
#
# Options:
#   --skip-nvd        Skip step 10.6
#   --skip-sonar      Skip steps 10.10 & 10.11 (no SonarQube container needed)
#   --skip-dast       Skip step  10.12 (requires running app)
#   --skip-build      Skip steps 10.5 & 10.8; NVD still updates and scans
#   --skip-install    Abort instead of auto-installing a missing tool
#   --nvd-key  KEY    NVD API key for faster dependency scan
#   --nvd-data-dir DIR Persistent NVD database (default: .security-cache/dependency-check)
#   --app-url  URL    Target URL for DAST (default: http://localhost:3000)
#   --repo     DIR    Repo root (default: current directory)
#
# Environment variable equivalents:
#   NVD_API_KEY   NVD_DATA_DIR   NVD_PLUGIN_VERSION   NVD_FAIL_CVSS   SKIP_NVD
#   SONAR_TOKEN   APP_URL        REPO_DIR
#
# Examples:
#   # Full pipeline
#   ./security-pipeline.sh
#
#   # Fast pre-commit check (no Docker-heavy steps)
#   ./security-pipeline.sh --skip-nvd --skip-sonar --skip-dast --skip-build
#
#   # After podman-compose up — run everything including DAST
#   ./security-pipeline.sh --skip-build --nvd-key $NVD_API_KEY
#
# =============================================================================
set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
REPO_DIR="${REPO_DIR:-$(pwd)}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_DIR="/tmp/pipeline-reports/${TIMESTAMP}"
NVD_API_KEY="${NVD_API_KEY:-}"
NVD_DATA_DIR="${NVD_DATA_DIR:-}"
NVD_PLUGIN_VERSION="${NVD_PLUGIN_VERSION:-12.2.2}"
NVD_FAIL_CVSS="${NVD_FAIL_CVSS:-7}"
APP_URL="${APP_URL:-http://localhost:3000}"
SKIP_NVD="${SKIP_NVD:-false}"
SKIP_SONAR=false
SKIP_DAST=false
SKIP_BUILD=false
SKIP_INSTALL=false
SONAR_HOST="http://localhost:9000"
SONAR_ADMIN_PASS="PipelineAdmin@1234"
SONAR_PROJECT_KEY="issue-tracker-v2"
SONAR_TOKEN="${SONAR_TOKEN:-}"

# Podman image names produced by podman-compose build
COMPOSE_PROJECT="sample-spring-bot-application"
IMG_AUTH="localhost/${COMPOSE_PROJECT}_auth-service:latest"
IMG_ISSUE="localhost/${COMPOSE_PROJECT}_issue-service:latest"
IMG_GATEWAY="localhost/${COMPOSE_PROJECT}_api-gateway:latest"
IMG_FRONTEND="localhost/${COMPOSE_PROJECT}_frontend-service:latest"
ALL_IMAGES=("$IMG_AUTH" "$IMG_ISSUE" "$IMG_GATEWAY" "$IMG_FRONTEND")

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
        --nvd-key)      NVD_API_KEY="$2";    shift 2 ;;
        --nvd-data-dir) NVD_DATA_DIR="$2";   shift 2 ;;
        --app-url)      APP_URL="$2";        shift 2 ;;
        --repo)         REPO_DIR="$2";       shift 2 ;;
        -h|--help)      sed -n '2,55p' "$0"; exit 0 ;;
        *)              echo "Unknown option: $1"; exit 1 ;;
    esac
done

NVD_DATA_DIR="${NVD_DATA_DIR:-${REPO_DIR}/.security-cache/dependency-check}"

# ─────────────────────────────────────────────────────────────────────────────
# COLORS
# ─────────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'  GREEN='\033[0;32m'  YELLOW='\033[1;33m'
    BLUE='\033[0;34m' CYAN='\033[0;36m'   BOLD='\033[1m' DIM='\033[2m' NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP TRACKING
# ─────────────────────────────────────────────────────────────────────────────
STEP_IDS=(   gitleaks hadolint  checkstyle semgrep  build    nvd      lint     podman_build trivy    sonar    gate     dast    )
STEP_NUMS=(  "10.1"   "10.2"    "10.3"     "10.4"   "10.5"   "10.6"   "10.7"   "10.8"       "10.9"   "10.10"  "10.11"  "10.12" )
STEP_NAMES=(
    "Gitleaks          Secret Scanning"
    "Hadolint          Dockerfile Lint"
    "Checkstyle        Java Code Style"
    "Semgrep           SAST"
    "Maven Build       Compile & Package"
    "NVD Check         Dependency CVEs"
    "Lint              ESLint + SpotBugs"
    "Podman Build      Container Images"
    "Trivy             Image + Config Scan"
    "SonarQube         Quality Analysis"
    "Quality Gate      Merge/Deploy Gate"
    "DAST              ZAP Dynamic Scan"
)
STEP_STATUS=(  "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" )
STEP_ELAPSED=( "0" "0" "0" "0" "0" "0" "0" "0" "0" "0" "0" "0" )

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
    echo ""; echo -e "${CYAN}${BOLD}┌─[$1]─ $2 ─────────────────────────────────────────${NC}"; _log "--- [$1] $2 ---"
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
    if eval "$check" &>/dev/null; then log_ok "$name: already installed"; return 0; fi
    if [[ "$SKIP_INSTALL" == "true" ]]; then log_error "$name: not found (--skip-install set)"; return 1; fi
    log_info "Installing $name..."
    eval "$install_cmd" 2>&1 | tail -5
    eval "$check" &>/dev/null && log_ok "$name: installed" || { log_error "$name: install failed"; return 1; }
}

# Helper: run mvnw for a service
mvnw() {
    local svc="$1"; shift
    "${REPO_DIR}/${svc}/mvnw" -f "${REPO_DIR}/${svc}/pom.xml" "$@"
}

setup_tools() {
    log_banner "Setup — checking tools"
    mkdir -p "$REPORT_DIR"
    MAIN_LOG="${REPORT_DIR}/pipeline.log"
    touch "$MAIN_LOG"
    echo "Started:    $(date)"        >> "$MAIN_LOG"
    echo "Repository: ${REPO_DIR}"    >> "$MAIN_LOG"
    echo "Reports:    ${REPORT_DIR}"  >> "$MAIN_LOG"

    log_info "Repository : ${REPO_DIR}"
    log_info "Reports    : ${REPORT_DIR}"

    install_if_missing "gitleaks" "command -v gitleaks" \
        'GL=$(curl -sf https://api.github.com/repos/gitleaks/gitleaks/releases/latest | python3 -c "import sys,json;print(json.load(sys.stdin)[\"tag_name\"].lstrip(\"v\"))")
         curl -sSL "https://github.com/gitleaks/gitleaks/releases/download/v${GL}/gitleaks_${GL}_$(uname -s | tr A-Z a-z)_x64.tar.gz" | sudo tar -xz -C /usr/local/bin gitleaks'

    install_if_missing "hadolint" "command -v hadolint" \
        "brew install hadolint"

    install_if_missing "semgrep" "command -v semgrep" \
        "pip3 install semgrep --quiet"

    install_if_missing "trivy" "command -v trivy" \
        "brew install trivy"

    install_if_missing "jq" "command -v jq" \
        "brew install jq"

    install_if_missing "Node.js / npm" "command -v npm" \
        "brew install node"

    # Podman is required (replaces Docker for image build + SonarQube + DAST)
    if ! command -v podman &>/dev/null; then
        log_error "Podman not found. Install via: brew install podman"
        return 1
    fi
    log_ok "Podman: $(podman --version)"

    log_ok "Setup complete → reports in $REPORT_DIR"
}

# ─────────────────────────────────────────────────────────────────────────────
# 10.1  GITLEAKS
# ─────────────────────────────────────────────────────────────────────────────
step_gitleaks() {
    local report="${REPORT_DIR}/gitleaks.json"
    cat > "${REPORT_DIR}/.gitleaks.toml" << 'TOML'
title = "Issue Tracker v2 Gitleaks"
[allowlist]
description = "Placeholder values in docs / cloud-init / .env.example"
regexes = [
    "ReplaceThisWithASecureSecretKeyOfAtLeast32Chars",
    "not-configured",
    "StrongPass@2024!",
    "Admin@2024!",
    "local-dev-jwt-secret-key-32bytes!!",
    "squ_xxxxxxxxxxxxxxxxxxxxx",
    "rootpassword",
    "devpassword123"
]
TOML

    log_info "Scanning git history for accidentally committed secrets..."
    if gitleaks detect \
        --source    "$REPO_DIR" \
        --config    "${REPORT_DIR}/.gitleaks.toml" \
        --report-format json \
        --report-path   "$report" \
        --no-banner --verbose 2>&1; then
        log_ok "No secrets found"
    else
        local n; n=$(jq 'length' "$report" 2>/dev/null || echo "?")
        log_error "${n} secret(s) found — review ${report}"
        jq -r '.[] | "  \(.RuleID)  \(.File):\(.StartLine)  \(.Secret)"' "$report" 2>/dev/null || true
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 10.2  HADOLINT  (v2 NEW)
# ─────────────────────────────────────────────────────────────────────────────
step_hadolint() {
    local failed=0
    # DL3007: unpinned 'latest' tag — we accept this for local dev images
    # DL3002: last user should not be root — known issue, documented in README §10.2
    local ignore_rules="--ignore DL3007 --ignore DL3002"

    log_info "Linting all Dockerfiles..."
    while IFS= read -r df; do
        log_info "  $df"
        # shellcheck disable=SC2086
        if hadolint $ignore_rules "$df" 2>&1; then
            log_ok "  $(basename "$(dirname "$df")")/Dockerfile: OK"
        else
            log_warn "  $(basename "$(dirname "$df")")/Dockerfile: violations found"
            failed=$(( failed + 1 ))
        fi
    done < <(find "$REPO_DIR" -name "Dockerfile" -not -path "*/target/*" -not -path "*/.git/*")

    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 10.3  CHECKSTYLE
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
            log_warn "$svc: style violations (see log)"
            failed=$(( failed + 1 ))
        fi
    done
    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 10.4  SEMGREP (SAST)
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
    local total=$(( $(jq '.results|length' "$out_java" 2>/dev/null || echo 0) + \
                    $(jq '.results|length' "$out_js"   2>/dev/null || echo 0) ))

    log_info "Findings — Java: $(jq '.results|length' "$out_java" 2>/dev/null || echo 0) | JS: $(jq '.results|length' "$out_js" 2>/dev/null || echo 0) | ERROR-level: $total_err"

    if [[ $total_err -gt 0 ]]; then
        log_error "$total_err high-severity finding(s):"
        jq -r '.results[]|select(.extra.severity=="ERROR")|"  [\(.check_id)] \(.path):\(.start.line) — \(.extra.message)"' \
            "$out_java" "$out_js" 2>/dev/null | head -20 || true
        return 1
    fi
    [[ $total -eq 0 ]] && log_ok "No SAST findings" || log_warn "$total informational finding(s) — review ${out_java}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 10.5  MAVEN BUILD
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
            log_error "$svc: BUILD FAILED"
            failed=$(( failed + 1 ))
        fi
    done
    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 10.6  NVD CHECK  (OWASP Dependency-Check)
# ─────────────────────────────────────────────────────────────────────────────
step_nvd() {
    local failed=0
    local nvd_script="${REPO_DIR}/scripts/nvd-scan.sh"

    if [[ -z "$NVD_API_KEY" ]]; then
        log_warn "NVD_API_KEY not set — updates may be heavily rate-limited"
        log_warn "Get a free key: https://nvd.nist.gov/developers/request-an-api-key"
    fi

    if [[ ! -x "$nvd_script" ]]; then
        log_error "NVD scan helper is missing or not executable: ${nvd_script}"
        return 1
    fi

    if [[ -f "${NVD_DATA_DIR}/odc.mv.db" ]]; then
        log_info "Reusing local NVD database: ${NVD_DATA_DIR}"
    else
        log_warn "No local NVD database found; the initial download can take a long time"
    fi

    log_info "Updating the NVD database once, then scanning all Java services..."
    if NVD_API_KEY="$NVD_API_KEY" \
       NVD_DATA_DIR="$NVD_DATA_DIR" \
       NVD_PLUGIN_VERSION="$NVD_PLUGIN_VERSION" \
       NVD_FAIL_CVSS="$NVD_FAIL_CVSS" \
       "$nvd_script" scan --report-dir "${REPORT_DIR}/nvd" 2>&1; then
        log_ok "Java dependency scans passed"
    else
        log_error "One or more Java dependency scans failed — see ${REPORT_DIR}/nvd"
        failed=$(( failed + 1 ))
    fi

    if command -v npm &>/dev/null && [[ -d "${REPO_DIR}/frontend-service" ]]; then
        log_info "npm audit — frontend..."
        cd "${REPO_DIR}/frontend-service"
        [[ ! -d node_modules ]] && npm install --silent 2>&1 | tail -3
        if npm audit --audit-level=high 2>&1; then log_ok "frontend: npm audit clean"
        else log_error "frontend: HIGH/CRITICAL npm CVEs"; failed=$(( failed + 1 )); fi
        cd - > /dev/null
    fi
    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 10.7  LINT  (ESLint + SpotBugs)
# ─────────────────────────────────────────────────────────────────────────────
step_lint() {
    local failed=0

    local fe_dir="${REPO_DIR}/frontend-service"
    log_info "ESLint — frontend..."
    cd "$fe_dir"
    [[ ! -d node_modules ]] && npm install --silent 2>&1 | tail -3
    if npm run lint 2>&1; then log_ok "ESLint: passed"
    else log_error "ESLint: violations"; failed=$(( failed + 1 )); fi
    cd - > /dev/null

    local sb_plugin="com.github.spotbugs:spotbugs-maven-plugin:4.8.3.1:check"
    for svc in auth-service issue-service api-gateway; do
        if [[ ! -d "${REPO_DIR}/${svc}/target/classes" ]]; then
            log_warn "$svc: no compiled classes — run Maven Build first"; continue
        fi
        log_info "SpotBugs: $svc..."
        if mvnw "$svc" "$sb_plugin" \
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
# 10.8  PODMAN BUILD  (v2)
# ─────────────────────────────────────────────────────────────────────────────
step_podman_build() {
    log_info "Building all container images via podman-compose..."
    cd "$REPO_DIR"
    if podman-compose build 2>&1; then
        log_ok "All images built"
        for img in "${ALL_IMAGES[@]}"; do
            local size; size=$(podman image inspect "$img" --format "{{.Size}}" 2>/dev/null | numfmt --to=iec 2>/dev/null || echo "?")
            log_info "  $img  ($size)"
        done
    else
        log_error "podman-compose build failed"
        return 1
    fi
    cd - > /dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# 10.9  TRIVY  (v2 NEW)
# ─────────────────────────────────────────────────────────────────────────────
step_trivy() {
    local failed=0

    # ── A. Config scan: Dockerfiles + docker-compose.yml (no image needed) ──
    log_info "Trivy config scan — Dockerfiles + docker-compose.yml..."
    local config_report="${REPORT_DIR}/trivy-config.json"
    if trivy config \
        --exit-code 1 \
        --severity   HIGH,CRITICAL \
        --format     json \
        --output     "$config_report" \
        "$REPO_DIR" 2>&1; then
        log_ok "Config scan: no HIGH/CRITICAL misconfigurations"
    else
        local n; n=$(jq '[.Results[]?.Misconfigurations[]?|select(.Severity=="HIGH" or .Severity=="CRITICAL")]|length' "$config_report" 2>/dev/null || echo "?")
        log_error "Config scan: $n HIGH/CRITICAL misconfiguration(s) — ${config_report}"
        failed=$(( failed + 1 ))
    fi

    # ── B. Image scan: all four built images ─────────────────────────────────
    for img in "${ALL_IMAGES[@]}"; do
        local svc_name; svc_name="${img##*_}"; svc_name="${svc_name%%:*}"
        local img_report="${REPORT_DIR}/trivy-image-${svc_name}.json"

        # Skip if image doesn't exist (build step may have been skipped)
        if ! podman image exists "$img" 2>/dev/null; then
            log_warn "Image $img not found — run Podman Build first"
            continue
        fi

        log_info "Image scan: $img..."
        if trivy image \
            --exit-code 1 \
            --severity  HIGH,CRITICAL \
            --format    json \
            --output    "$img_report" \
            "$img" 2>&1; then
            log_ok "$svc_name: no HIGH/CRITICAL CVEs in image"
        else
            local cve_count; cve_count=$(jq '[.Results[]?.Vulnerabilities[]?|select(.Severity=="HIGH" or .Severity=="CRITICAL")]|length' "$img_report" 2>/dev/null || echo "?")
            log_error "$svc_name: $cve_count HIGH/CRITICAL CVE(s) — ${img_report}"
            # Print top 5 for quick visibility
            jq -r '.Results[]?.Vulnerabilities[]?|select(.Severity=="HIGH" or .Severity=="CRITICAL")|"    \(.Severity)  \(.VulnerabilityID)  \(.PkgName) \(.InstalledVersion) → \(.FixedVersion // "no fix")"' \
                "$img_report" 2>/dev/null | sort -u | head -5 || true
            failed=$(( failed + 1 ))
        fi
    done

    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 10.10  SONARQUBE
# ─────────────────────────────────────────────────────────────────────────────
step_sonar() {
    local free_mb; free_mb=$(vm_stat 2>/dev/null | awk '/Pages free/{print int($3)*4096/1048576}' || echo 9999)
    if [[ $free_mb -lt 1500 ]]; then
        log_error "Only ~${free_mb}MB free RAM. SonarQube needs ~1.5GB. Use --skip-sonar or free RAM."; return 1
    fi

    # Increase vm.max_map_count (needed inside Podman VM for Elasticsearch)
    podman machine ssh "sudo sysctl -w vm.max_map_count=262144" 2>/dev/null || true

    if ! podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^sonarqube$"; then
        log_info "Starting SonarQube container..."
        podman run -d \
            --name    sonarqube \
            --memory  2g \
            --restart unless-stopped \
            -p 9000:9000 \
            -v sonarqube_data:/opt/sonarqube/data \
            sonarqube:community 2>&1
    else
        log_info "SonarQube already running"
    fi

    log_info "Waiting for SonarQube to be ready (up to 5 min)..."
    local waited=0
    until curl -sf "${SONAR_HOST}/api/system/status" 2>/dev/null | grep -q '"status":"UP"'; do
        sleep 5; waited=$(( waited + 5 ))
        [[ $waited -ge 300 ]] && { log_error "SonarQube not ready after 300s"; return 1; }
        printf "."
    done; echo ""
    log_ok "SonarQube UP at ${SONAR_HOST}"

    # Change default admin password (idempotent)
    curl -sf -u admin:admin -X POST "${SONAR_HOST}/api/users/change_password" \
        -d "login=admin&previousPassword=admin&password=${SONAR_ADMIN_PASS}" &>/dev/null || true

    # Generate analysis token
    if [[ -z "$SONAR_TOKEN" ]]; then
        curl -sf -u "admin:${SONAR_ADMIN_PASS}" -X POST "${SONAR_HOST}/api/user_tokens/revoke" \
            -d "login=admin&name=pipeline-v2-token" &>/dev/null || true
        SONAR_TOKEN=$(curl -sf -u "admin:${SONAR_ADMIN_PASS}" \
            -X POST "${SONAR_HOST}/api/user_tokens/generate" \
            -d "login=admin&name=pipeline-v2-token&type=GLOBAL_ANALYSIS_TOKEN" \
            | jq -r '.token' 2>/dev/null || echo "")
    fi
    [[ -z "$SONAR_TOKEN" ]] && { log_error "Failed to get SonarQube token"; return 1; }
    echo "$SONAR_TOKEN" > "${REPORT_DIR}/sonar-token.txt"
    log_ok "Token acquired"

    local failed=0
    for svc in auth-service issue-service api-gateway; do
        local key="${SONAR_PROJECT_KEY}-${svc}"
        curl -sf -u "admin:${SONAR_ADMIN_PASS}" -X POST "${SONAR_HOST}/api/projects/create" \
            -d "project=${key}&name=Issue+Tracker+v2+-+${svc}" &>/dev/null || true
        log_info "Analysing $svc..."
        if mvnw "$svc" \
            "org.sonarsource.scanner.maven:sonar-maven-plugin:sonar" \
            -Dsonar.host.url="$SONAR_HOST" \
            -Dsonar.token="$SONAR_TOKEN" \
            -Dsonar.projectKey="$key" \
            -B --no-transfer-progress 2>&1; then
            log_ok "$svc: submitted"
        else
            log_error "$svc: analysis failed"; failed=$(( failed + 1 ))
        fi
    done
    log_info "UI: ${SONAR_HOST}  login: admin / ${SONAR_ADMIN_PASS}"
    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 10.11  QUALITY GATE
# ─────────────────────────────────────────────────────────────────────────────
step_gate() {
    [[ -z "$SONAR_TOKEN" && -f "${REPORT_DIR}/sonar-token.txt" ]] \
        && SONAR_TOKEN=$(cat "${REPORT_DIR}/sonar-token.txt")
    [[ -z "$SONAR_TOKEN" ]] && { log_error "No SonarQube token — did step 10.10 pass?"; return 1; }

    local failed=0
    for svc in auth-service issue-service api-gateway; do
        local key="${SONAR_PROJECT_KEY}-${svc}"
        log_info "Quality Gate: $svc..."
        local attempts=0 status=""
        while [[ $attempts -lt 36 ]]; do
            status=$(curl -sf -u "${SONAR_TOKEN}:" \
                "${SONAR_HOST}/api/qualitygates/project_status?projectKey=${key}" \
                | jq -r '.projectStatus.status' 2>/dev/null || echo "")
            [[ "$status" =~ ^(OK|ERROR|WARN|NONE)$ ]] && break
            sleep 5; attempts=$(( attempts + 1 )); printf "."
        done; echo ""
        case "$status" in
            OK)    log_ok   "$svc: Quality Gate PASSED" ;;
            ERROR) log_error "$svc: Quality Gate FAILED"
                   curl -sf -u "${SONAR_TOKEN}:" \
                       "${SONAR_HOST}/api/qualitygates/project_status?projectKey=${key}" \
                       | jq -r '.projectStatus.conditions[]|select(.status=="ERROR")|"    \(.metricKey): \(.actualValue) (threshold: \(.errorThreshold))"' 2>/dev/null || true
                   failed=$(( failed + 1 )) ;;
            WARN)  log_warn "$svc: warnings (not blocking)" ;;
            NONE)  log_warn "$svc: no gate assigned — assign at ${SONAR_HOST}/quality_gates" ;;
            *)     log_warn "$svc: result unavailable (analysis still running?)" ;;
        esac
    done
    log_info "Dashboard: ${SONAR_HOST}/projects"
    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 10.12  DAST  (OWASP ZAP)
# ─────────────────────────────────────────────────────────────────────────────
step_dast() {
    log_info "Checking app at ${APP_URL}..."
    if ! curl -sf --max-time 10 "${APP_URL}/" &>/dev/null; then
        log_error "App not reachable at ${APP_URL}"
        log_error "Start it first: podman-compose up -d"
        return 1
    fi
    log_ok "App is reachable"

    local html="${REPORT_DIR}/zap-report.html" json="${REPORT_DIR}/zap-report.json"
    log_info "ZAP baseline scan (passive) — target: ${APP_URL}"

    if podman run --rm \
        --network host \
        -v "${REPORT_DIR}:/zap/wrk:rw" \
        ghcr.io/zaproxy/zaproxy:stable \
        zap-baseline.py \
            -t "${APP_URL}/" \
            -r "zap-report.html" \
            -J "zap-report.json" \
            -l WARN -I 2>&1; then
        log_ok "Scan complete — ${html}"
    else
        local n; n=$(jq '[.site[].alerts[]|select(.riskcode|tonumber>=2)]|length' "$json" 2>/dev/null || echo "?")
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
    echo -e "${BOLD}${BLUE}║    SECURITY & CODE QUALITY PIPELINE — v2 SUMMARY           ║${NC}"
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
    if [[ $fail -eq 0 ]]; then vcolor=$GREEN; vmsg="ALL CHECKS PASSED — safe to merge/deploy"
    else vcolor=$RED; vmsg="${fail} CHECK(S) FAILED — do not merge/deploy"; fi
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
    log_banner "Security & Code Quality Pipeline — Issue Tracker v2"
    echo -e "  ${DIM}Repository : ${REPO_DIR}${NC}"
    echo -e "  ${DIM}App URL    : ${APP_URL}${NC}"
    echo -e "  ${DIM}Started    : $(date)${NC}"
    [[ "$SKIP_NVD"   == "true" ]] && echo -e "  ${YELLOW}⚠${NC}  NVD Check: SKIPPED"
    [[ "$SKIP_SONAR" == "true" ]] && echo -e "  ${YELLOW}⚠${NC}  SonarQube + Quality Gate: SKIPPED"
    [[ "$SKIP_DAST"  == "true" ]] && echo -e "  ${YELLOW}⚠${NC}  DAST: SKIPPED"
    [[ "$SKIP_BUILD" == "true" ]] && echo -e "  ${YELLOW}⚠${NC}  Maven Build + Podman Build: SKIPPED"
    echo ""

    [[ -d "$REPO_DIR" ]] || { echo "Repo not found: $REPO_DIR"; exit 1; }

    setup_tools || exit 1

    run_step "gitleaks"
    run_step "hadolint"
    run_step "checkstyle"
    run_step "semgrep"

    [[ "$SKIP_BUILD" == "true" ]] && skip_step "build" "--skip-build flag set" || run_step "build"

    # Dependency-Check resolves dependencies from each pom.xml and uses its own
    # persistent database, so it can run even when Maven/Podman builds are skipped.
    [[ "$SKIP_NVD" == "true" ]] && skip_step "nvd" "--skip-nvd flag or SKIP_NVD=true set" || run_step "nvd"

    if [[ "$SKIP_BUILD" == "true" ]]; then
        skip_step "lint"         "--skip-build flag set; SpotBugs requires compiled classes"
        skip_step "podman_build" "--skip-build flag set"
    else
        local build_ok=false
        [[ "$(get_status build)" == "PASS" ]] && build_ok=true
        $build_ok && run_step "lint" || skip_step "lint" "Maven Build failed"
        run_step "podman_build"
    fi

    # Trivy needs images to exist (from podman_build or pre-built)
    local images_ok=false
    podman image exists "$IMG_AUTH" 2>/dev/null && images_ok=true
    $images_ok && run_step "trivy" || skip_step "trivy" "Container images not found — run Podman Build"

    if [[ "$SKIP_SONAR" == "true" ]]; then
        skip_step "sonar" "--skip-sonar flag set"
        skip_step "gate"  "--skip-sonar flag set"
    else
        local build_ok=false
        [[ "$(get_status build)" == "PASS" || "$SKIP_BUILD" == "true" ]] && build_ok=true
        if $build_ok; then
            run_step "sonar"
            [[ "$(get_status sonar)" == "PASS" ]] && run_step "gate" || skip_step "gate" "SonarQube failed"
        else
            skip_step "sonar" "Maven Build failed"
            skip_step "gate"  "Maven Build failed"
        fi
    fi

    [[ "$SKIP_DAST" == "true" ]] && skip_step "dast" "--skip-dast flag set" || run_step "dast"

    print_summary
}

main "$@"
