#!/usr/bin/env bash
# =============================================================================
# security-pipeline.sh  —  Security & Code Quality Pipeline  (v3 / Kind)
# Issue Tracker v3 | Run on the developer machine or CI agent
# =============================================================================
#
# Pipeline steps (README §12):
#   12.1  Gitleaks        — secret scanning
#   12.2  Hadolint        — Dockerfile linting
#   12.3  Trivy config    — Dockerfiles + docker-compose.yml + Kubernetes YAML
#   12.4  Kubesec         — K8s manifest security risk scoring  [v3 NEW]
#   12.5  kube-score      — K8s best-practice analysis          [v3 NEW]
#   12.6  Checkstyle      — Java code style
#   12.6  Semgrep         — SAST (Java + JS/React)
#   12.6  Maven Build     — compile & package all services
#   12.6  NVD Check       — dependency CVE scanning
#   12.6  Lint            — ESLint (React) + SpotBugs (Java)
#   12.7  Podman Build    — build container images
#   12.7  Trivy image     — image CVE + secret scan
#   12.8  SonarQube       — deep quality & security analysis
#   12.8  Quality Gate    — SonarQube merge gate
#   12.9  DAST            — OWASP ZAP against the running kind cluster
#
# Usage:
#   chmod +x security-pipeline.sh
#   ./security-pipeline.sh [OPTIONS]
#
# Options:
#   --skip-sonar      Skip steps 12.8 SonarQube + Quality Gate
#   --skip-dast       Skip step  12.9 DAST (requires kind cluster running)
#   --skip-build      Skip Maven Build + Podman Build (use cached JARs/images)
#   --skip-install    Abort if a tool is missing instead of installing it
#   --nvd-key  KEY    NVD API key for faster dependency scan
#   --app-url  URL    Target URL for DAST (default: http://sample-app.kind.local)
#   --repo     DIR    Repo root (default: current directory)
#
# Examples:
#   # Quick pre-commit check (~2 min)
#   ./security-pipeline.sh --skip-sonar --skip-dast --skip-build
#
#   # Full pipeline with NVD key
#   ./security-pipeline.sh --nvd-key $NVD_API_KEY
#
#   # DAST against the running kind cluster
#   ./security-pipeline.sh --skip-build --skip-sonar --app-url http://sample-app.kind.local
# =============================================================================
set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
REPO_DIR="${REPO_DIR:-$(pwd)}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_DIR="/tmp/pipeline-reports/${TIMESTAMP}"
NVD_API_KEY="${NVD_API_KEY:-}"
APP_URL="${APP_URL:-http://sample-app.kind.local}"
SKIP_SONAR=false
SKIP_DAST=false
SKIP_BUILD=false
SKIP_INSTALL=false
SONAR_HOST="http://localhost:9000"
SONAR_ADMIN_PASS="PipelineAdmin@1234"
SONAR_PROJECT_KEY="issue-tracker-v3"
SONAR_TOKEN="${SONAR_TOKEN:-}"

# Images built with Podman (localhost/ prefix is required — see README §6.3)
IMAGES=(
  "localhost/api-gateway:local"
  "localhost/auth-service:local"
  "localhost/issue-service:local"
  "localhost/frontend-service:local"
)

# kubesec: ARM64 local image is unavailable; use the public API instead
KUBESEC_API="https://v2.kubesec.io/scan"
# Minimum acceptable kubesec score (0 = no critical negatives; raise after hardening)
KUBESEC_MIN_SCORE=0

# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-sonar)   SKIP_SONAR=true;     shift ;;
        --skip-dast)    SKIP_DAST=true;      shift ;;
        --skip-build)   SKIP_BUILD=true;     shift ;;
        --skip-install) SKIP_INSTALL=true;   shift ;;
        --nvd-key)      NVD_API_KEY="$2";    shift 2 ;;
        --app-url)      APP_URL="$2";        shift 2 ;;
        --repo)         REPO_DIR="$2";       shift 2 ;;
        -h|--help)      sed -n '2,60p' "$0"; exit 0 ;;
        *)              echo "Unknown option: $1"; exit 1 ;;
    esac
done

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
STEP_IDS=(   gitleaks  hadolint  trivy_config  kubesec   kube_score  checkstyle  semgrep  build    nvd      lint     podman_build  trivy_image  sonar    gate     dast    )
STEP_NUMS=(  "12.1"    "12.2"    "12.3"        "12.4"    "12.5"      "12.6a"     "12.6b"  "12.6c"  "12.6d"  "12.6e"  "12.7a"       "12.7b"      "12.8a"  "12.8b"  "12.9"  )
STEP_NAMES=(
    "Gitleaks          Secret Scanning"
    "Hadolint          Dockerfile Lint"
    "Trivy Config      Dockerfiles + K8s YAML"
    "Kubesec           K8s Manifest Scoring"
    "kube-score        K8s Best-Practice"
    "Checkstyle        Java Code Style"
    "Semgrep           SAST"
    "Maven Build       Compile & Package"
    "NVD Check         Dependency CVEs"
    "Lint              ESLint + SpotBugs"
    "Podman Build      Container Images"
    "Trivy Image       Image CVE Scan"
    "SonarQube         Quality Analysis"
    "Quality Gate      Merge/Deploy Gate"
    "DAST              ZAP vs Kind Cluster"
)
STEP_STATUS=(  "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" )
STEP_ELAPSED=( "0" "0" "0" "0" "0" "0" "0" "0" "0" "0" "0" "0" "0" "0" "0" )

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

setup_tools() {
    log_banner "Setup — checking tools"
    mkdir -p "$REPORT_DIR"
    MAIN_LOG="${REPORT_DIR}/pipeline.log"
    touch "$MAIN_LOG"
    echo "Started:    $(date)"        >> "$MAIN_LOG"
    echo "Repository: ${REPO_DIR}"    >> "$MAIN_LOG"
    echo "App URL:    ${APP_URL}"     >> "$MAIN_LOG"
    echo "Reports:    ${REPORT_DIR}"  >> "$MAIN_LOG"

    log_info "Repository : ${REPO_DIR}"
    log_info "App URL    : ${APP_URL}"
    log_info "Reports    : ${REPORT_DIR}"

    install_if_missing "gitleaks" "command -v gitleaks" \
        'GL=$(curl -sf https://api.github.com/repos/gitleaks/gitleaks/releases/latest | python3 -c "import sys,json;print(json.load(sys.stdin)[\"tag_name\"].lstrip(\"v\"))")
         curl -sSL "https://github.com/gitleaks/gitleaks/releases/download/v${GL}/gitleaks_${GL}_$(uname -s | tr A-Z a-z)_x64.tar.gz" \
           | tar -xz -C /usr/local/bin gitleaks'
    install_if_missing "hadolint"   "command -v hadolint"   "brew install hadolint"
    install_if_missing "trivy"      "command -v trivy"      "brew install trivy"
    install_if_missing "semgrep"    "command -v semgrep"    "pip3 install semgrep --quiet"
    install_if_missing "kube-score" "command -v kube-score" "brew install kube-score"
    install_if_missing "jq"         "command -v jq"         "brew install jq"
    install_if_missing "node/npm"   "command -v npm"        "brew install node"

    # kubesec: no ARM64 image — verify public API is reachable instead
    if curl -sf --max-time 5 "https://v2.kubesec.io/scan" -X POST \
        -H "Content-Type: application/json" \
        -d '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"test"}}' &>/dev/null; then
        log_ok "kubesec: public API reachable (https://v2.kubesec.io/scan)"
    else
        log_warn "kubesec: public API not reachable — step 12.4 will be skipped"
    fi

    if ! command -v podman &>/dev/null; then
        log_error "podman: not found — install with: brew install podman"
        return 1
    fi
    log_ok "podman: $(podman --version)"

    log_ok "All tools ready"
}

# ─────────────────────────────────────────────────────────────────────────────
# 12.1  GITLEAKS
# ─────────────────────────────────────────────────────────────────────────────
step_gitleaks() {
    local report="${REPORT_DIR}/gitleaks.json"
    cat > "${REPORT_DIR}/.gitleaks.toml" << 'TOML'
title = "Issue Tracker v3 Gitleaks"
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
# 12.2  HADOLINT
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
               -not -path "*/target/*" -not -path "*/.git/*")
    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 12.3  TRIVY CONFIG  (v3: extended to Kubernetes YAML)
# ─────────────────────────────────────────────────────────────────────────────
step_trivy_config() {
    local report="${REPORT_DIR}/trivy-config.json"

    log_info "Trivy config scan — Dockerfiles + docker-compose.yml + Kubernetes YAML..."
    # --misconfiguration-scanners includes dockerfile AND kubernetes KSV rules
    if trivy config \
        --exit-code 1 \
        --severity  HIGH,CRITICAL \
        --format    json \
        --output    "$report" \
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
# 12.4  KUBESEC  (v3 NEW — uses public API for ARM64 compatibility)
# ─────────────────────────────────────────────────────────────────────────────
step_kubesec() {
    local report="${REPORT_DIR}/kubesec.json"
    local failed=0 total=0

    # Verify API is reachable
    if ! curl -sf --max-time 5 "${KUBESEC_API}" \
        -X POST -H "Content-Type: application/json" \
        -d '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"t"}}' &>/dev/null; then
        log_warn "kubesec API not reachable — skipping (offline environment?)"
        return 0
    fi

    log_info "Scoring Kubernetes Deployment manifests via kubesec API..."
    echo "[]" > "$report"

    while IFS= read -r manifest; do
        local svc_name; svc_name=$(basename "$(dirname "$manifest")")
        log_info "  Scanning $svc_name ($(basename "$manifest"))..."

        local result
        result=$(curl -sf --max-time 15 "${KUBESEC_API}" \
            -X POST -H "Content-Type: application/json" \
            --data-binary @"$manifest" 2>/dev/null || echo "[]")

        local score
        score=$(echo "$result" | jq -r '.[0].score // 0' 2>/dev/null || echo 0)
        local message
        message=$(echo "$result" | jq -r '.[0].message // "unknown"' 2>/dev/null)

        total=$(( total + 1 ))

        # Append to combined report
        echo "$result" | jq --arg f "$manifest" '.[0] + {file: $f}' >> "${report}.tmp" 2>/dev/null || true

        if [[ "$score" -ge "$KUBESEC_MIN_SCORE" ]]; then
            log_ok "  $svc_name: score=$score — $message"
        else
            log_warn "  $svc_name: score=$score (below min $KUBESEC_MIN_SCORE) — $message"
            # Print critical deductions
            echo "$result" | jq -r '.[0].scoring.critical[]? | "    [-\(.points)] \(.id): \(.reason)"' \
                2>/dev/null | head -5 || true
            failed=$(( failed + 1 ))
        fi
    done < <(find "$REPO_DIR/kubernetes/base/services" -name "deployment.yaml" \
               -not -path "*/.git/*" 2>/dev/null)

    # Also scan kind-specific patches
    if [[ -f "${REPO_DIR}/kubernetes/environments/kind/mysql/deployment.yaml" ]]; then
        log_info "  Scanning mysql deployment..."
        local result score
        result=$(curl -sf --max-time 15 "${KUBESEC_API}" \
            -X POST -H "Content-Type: application/json" \
            --data-binary @"${REPO_DIR}/kubernetes/environments/kind/mysql/deployment.yaml" 2>/dev/null || echo "[]")
        score=$(echo "$result" | jq -r '.[0].score // 0' 2>/dev/null || echo 0)
        log_info "  mysql: score=$score"
        total=$(( total + 1 ))
    fi

    log_info "$total manifest(s) scanned, $failed below threshold ($KUBESEC_MIN_SCORE)"
    log_info "Tip: raise KUBESEC_MIN_SCORE after adding securityContext to manifests"

    # kubesec is advisory for now — log failures but don't block pipeline
    if [[ $failed -gt 0 ]]; then
        log_warn "$failed manifest(s) scored below $KUBESEC_MIN_SCORE — see README §12.4 to harden"
    fi
    return 0   # non-blocking: hardening is incremental
}

# ─────────────────────────────────────────────────────────────────────────────
# 12.5  KUBE-SCORE  (v3 NEW)
# ─────────────────────────────────────────────────────────────────────────────
step_kube_score() {
    local report="${REPORT_DIR}/kube-score.txt"

    log_info "Rendering kind overlay via kustomize..."
    local rendered="${REPORT_DIR}/kind-rendered.yaml"
    kubectl kustomize "${REPO_DIR}/kubernetes/environments/kind" \
        --load-restrictor=LoadRestrictionsNone > "$rendered" 2>&1 || {
        log_error "kustomize render failed — cannot run kube-score"
        return 1
    }

    log_info "Running kube-score on rendered manifests..."
    # --ignore-test: ImagePullPolicy=Never is intentional for local kind dev
    kube-score score "$rendered" \
        --output-format ci \
        --ignore-test container-image-pull-policy \
        2>&1 | tee "$report"

    local critical_count
    critical_count=$(grep -c "^\[CRITICAL\]" "$report" 2>/dev/null || echo 0)
    local warning_count
    warning_count=$(grep -c "^\[WARNING\]" "$report" 2>/dev/null || echo 0)

    log_info "CRITICAL: $critical_count  |  WARNING: $warning_count"
    log_info "Full report: $report"

    if [[ "$critical_count" -gt 0 ]]; then
        log_warn "$critical_count CRITICAL finding(s) — see README §12.5 for recommended fixes"
        log_warn "(non-blocking — add probes and securityContext to resolve)"
    else
        log_ok "No CRITICAL kube-score findings"
    fi
    # Non-blocking: kube-score improvements are tracked as tech debt
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 12.6a  CHECKSTYLE
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
# 12.6b  SEMGREP
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
# 12.6c  MAVEN BUILD
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
# 12.6d  NVD CHECK
# ─────────────────────────────────────────────────────────────────────────────
step_nvd() {
    local plugin="org.owasp:dependency-check-maven:10.0.3:check"
    local failed=0
    if [[ -z "$NVD_API_KEY" ]]; then
        log_warn "NVD_API_KEY not set — first run downloads full NVD DB (~10-30 min)"
        log_warn "Set: export NVD_API_KEY=... (free key at nvd.nist.gov/developers/request-an-api-key)"
    fi
    local opts="-DfailBuildOnCVSS=7 -DskipTestScope=true -Dformats=HTML,JSON"
    [[ -n "$NVD_API_KEY" ]] && opts+=" -DnvdApiKey=${NVD_API_KEY}"
    for svc in auth-service issue-service api-gateway; do
        log_info "NVD scan: $svc..."
        # shellcheck disable=SC2086
        if mvnw "$svc" "$plugin" $opts -B --no-transfer-progress 2>&1; then
            log_ok "$svc: no CVSS≥7 vulnerabilities"
        else
            log_error "$svc: HIGH/CRITICAL CVEs — ${REPO_DIR}/${svc}/target/dependency-check-report.html"
            failed=$(( failed + 1 ))
        fi
    done
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
# 12.6e  LINT  (ESLint + SpotBugs)
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
# 12.7a  PODMAN BUILD
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
# 12.7b  TRIVY IMAGE SCAN
# ─────────────────────────────────────────────────────────────────────────────
step_trivy_image() {
    local failed=0
    for img in "${IMAGES[@]}"; do
        local svc_name; svc_name="${img##*/}"; svc_name="${svc_name%%:*}"
        local img_report="${REPORT_DIR}/trivy-image-${svc_name}.json"

        if ! podman image exists "$img" 2>/dev/null; then
            log_warn "Image $img not found — run Podman Build first"
            continue
        fi
        log_info "Scanning image: $img..."
        if trivy image \
            --exit-code 1 \
            --severity  HIGH,CRITICAL \
            --format    json \
            --output    "$img_report" \
            "$img" 2>&1; then
            log_ok "$svc_name: no HIGH/CRITICAL CVEs"
        else
            local n; n=$(jq '[.Results[]?.Vulnerabilities[]?|select(.Severity=="HIGH" or .Severity=="CRITICAL")]|length' \
                "$img_report" 2>/dev/null || echo "?")
            log_error "$svc_name: $n HIGH/CRITICAL CVE(s) — $img_report"
            jq -r '.Results[]?.Vulnerabilities[]?|select(.Severity=="HIGH" or .Severity=="CRITICAL")|"    \(.Severity)  \(.VulnerabilityID)  \(.PkgName) \(.InstalledVersion) → \(.FixedVersion//"no fix")"' \
                "$img_report" 2>/dev/null | sort -u | head -5 || true
            failed=$(( failed + 1 ))
        fi
    done
    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 12.8a  SONARQUBE
# ─────────────────────────────────────────────────────────────────────────────
step_sonar() {
    local free_mb; free_mb=$(vm_stat 2>/dev/null | awk '/Pages free/{print int($3)*4096/1048576}' || echo 9999)
    if [[ $free_mb -lt 1500 ]]; then
        log_error "Only ~${free_mb}MB free RAM — SonarQube needs ~1.5GB. Use --skip-sonar."; return 1
    fi
    podman machine ssh "sudo sysctl -w vm.max_map_count=262144" 2>/dev/null || true
    if ! podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^sonarqube$"; then
        log_info "Starting SonarQube container..."
        podman run -d --name sonarqube --memory 2g --restart unless-stopped \
            -p 9000:9000 -v sonarqube_data:/opt/sonarqube/data sonarqube:community 2>&1
    else
        log_info "SonarQube already running"
    fi
    log_info "Waiting for SonarQube (up to 5 min)..."
    local waited=0
    until curl -sf "${SONAR_HOST}/api/system/status" 2>/dev/null | grep -q '"status":"UP"'; do
        sleep 5; waited=$(( waited + 5 ))
        [[ $waited -ge 300 ]] && { log_error "SonarQube not ready after 300s"; return 1; }
        printf "."
    done; echo ""
    log_ok "SonarQube UP at ${SONAR_HOST}"

    curl -sf -u admin:admin -X POST "${SONAR_HOST}/api/users/change_password" \
        -d "login=admin&previousPassword=admin&password=${SONAR_ADMIN_PASS}" &>/dev/null || true

    if [[ -z "$SONAR_TOKEN" ]]; then
        curl -sf -u "admin:${SONAR_ADMIN_PASS}" -X POST "${SONAR_HOST}/api/user_tokens/revoke" \
            -d "login=admin&name=pipeline-v3-token" &>/dev/null || true
        SONAR_TOKEN=$(curl -sf -u "admin:${SONAR_ADMIN_PASS}" \
            -X POST "${SONAR_HOST}/api/user_tokens/generate" \
            -d "login=admin&name=pipeline-v3-token&type=GLOBAL_ANALYSIS_TOKEN" \
            | jq -r '.token' 2>/dev/null || echo "")
    fi
    [[ -z "$SONAR_TOKEN" ]] && { log_error "Failed to get SonarQube token"; return 1; }
    echo "$SONAR_TOKEN" > "${REPORT_DIR}/sonar-token.txt"
    log_ok "Token acquired"

    local failed=0
    for svc in auth-service issue-service api-gateway; do
        local key="${SONAR_PROJECT_KEY}-${svc}"
        curl -sf -u "admin:${SONAR_ADMIN_PASS}" -X POST "${SONAR_HOST}/api/projects/create" \
            -d "project=${key}&name=Issue+Tracker+v3+-+${svc}" &>/dev/null || true
        log_info "Analysing $svc..."
        if mvnw "$svc" "org.sonarsource.scanner.maven:sonar-maven-plugin:sonar" \
            -Dsonar.host.url="$SONAR_HOST" -Dsonar.token="$SONAR_TOKEN" \
            -Dsonar.projectKey="$key" -B --no-transfer-progress 2>&1; then
            log_ok "$svc: submitted"
        else
            log_error "$svc: analysis failed"; failed=$(( failed + 1 ))
        fi
    done
    log_info "UI: ${SONAR_HOST}  login: admin / ${SONAR_ADMIN_PASS}"
    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 12.8b  QUALITY GATE
# ─────────────────────────────────────────────────────────────────────────────
step_gate() {
    [[ -z "$SONAR_TOKEN" && -f "${REPORT_DIR}/sonar-token.txt" ]] \
        && SONAR_TOKEN=$(cat "${REPORT_DIR}/sonar-token.txt")
    [[ -z "$SONAR_TOKEN" ]] && { log_error "No SonarQube token — did step 12.8a pass?"; return 1; }
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
            OK)    log_ok   "$svc: Gate PASSED" ;;
            ERROR) log_error "$svc: Gate FAILED"
                   curl -sf -u "${SONAR_TOKEN}:" \
                       "${SONAR_HOST}/api/qualitygates/project_status?projectKey=${key}" \
                       | jq -r '.projectStatus.conditions[]|select(.status=="ERROR")|"    \(.metricKey): \(.actualValue) (threshold: \(.errorThreshold))"' \
                       2>/dev/null || true
                   failed=$(( failed + 1 )) ;;
            WARN)  log_warn "$svc: warnings (not blocking)" ;;
            *)     log_warn "$svc: result unavailable" ;;
        esac
    done
    log_info "Dashboard: ${SONAR_HOST}/projects"
    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 12.9  DAST  (ZAP against the running kind cluster)
# ─────────────────────────────────────────────────────────────────────────────
step_dast() {
    log_info "Checking kind cluster at ${APP_URL}..."
    if ! curl -sf --max-time 10 "${APP_URL}/" &>/dev/null; then
        log_error "App not reachable at ${APP_URL}"
        log_error "Deploy the kind cluster first: ./scripts/kind-deploy.sh"
        return 1
    fi
    log_ok "Cluster is reachable"

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
    echo -e "${BOLD}${BLUE}║    SECURITY & CODE QUALITY PIPELINE — v3 SUMMARY           ║${NC}"
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
    log_banner "Security & Code Quality Pipeline — Issue Tracker v3 (Kind)"
    echo -e "  ${DIM}Repository : ${REPO_DIR}${NC}"
    echo -e "  ${DIM}App URL    : ${APP_URL}${NC}"
    echo -e "  ${DIM}Started    : $(date)${NC}"
    [[ "$SKIP_SONAR" == "true" ]] && echo -e "  ${YELLOW}⚠${NC}  SonarQube + Quality Gate: SKIPPED"
    [[ "$SKIP_DAST"  == "true" ]] && echo -e "  ${YELLOW}⚠${NC}  DAST: SKIPPED"
    [[ "$SKIP_BUILD" == "true" ]] && echo -e "  ${YELLOW}⚠${NC}  Maven Build + Podman Build: SKIPPED"
    echo ""

    [[ -d "$REPO_DIR" ]] || { echo "Repo not found: $REPO_DIR"; exit 1; }
    setup_tools || exit 1

    # ── Source + K8s checks (no build needed) ──────────────────────────────
    run_step "gitleaks"
    run_step "hadolint"
    run_step "trivy_config"
    run_step "kubesec"
    run_step "kube_score"
    run_step "checkstyle"
    run_step "semgrep"

    # ── Build-dependent steps ───────────────────────────────────────────────
    if [[ "$SKIP_BUILD" == "true" ]]; then
        skip_step "build"        "--skip-build flag"
        skip_step "nvd"          "--skip-build flag"
        skip_step "lint"         "--skip-build flag"
        skip_step "podman_build" "--skip-build flag"
        skip_step "trivy_image"  "--skip-build flag"
    else
        run_step "build"

        local build_ok=false
        [[ "$(get_status build)" == "PASS" ]] && build_ok=true

        $build_ok && run_step "nvd"          || skip_step "nvd"          "Maven Build failed"
        $build_ok && run_step "lint"         || skip_step "lint"         "Maven Build failed"
        $build_ok && run_step "podman_build" || skip_step "podman_build" "Maven Build failed"

        local images_ok=false
        [[ "$(get_status podman_build)" == "PASS" ]] && images_ok=true
        $images_ok && run_step "trivy_image" || skip_step "trivy_image"  "Podman Build failed"
    fi

    # ── SonarQube ───────────────────────────────────────────────────────────
    if [[ "$SKIP_SONAR" == "true" ]]; then
        skip_step "sonar" "--skip-sonar flag"
        skip_step "gate"  "--skip-sonar flag"
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

    # ── DAST ────────────────────────────────────────────────────────────────
    [[ "$SKIP_DAST" == "true" ]] && skip_step "dast" "--skip-dast flag" || run_step "dast"

    print_summary
}

main "$@"
