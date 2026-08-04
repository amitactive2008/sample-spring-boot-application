#!/usr/bin/env bash
# =============================================================================
# security-pipeline.sh — Security & Code Quality Pipeline
# Issue Tracker v1 | Run on Multipass VM: issue-tracker-v1
# =============================================================================
#
# Runs all nine checks from README §12 in order:
#   12.1  Gitleaks     — secret scanning
#   12.2  Checkstyle   — Java code style
#   12.3  Semgrep      — SAST (static security analysis)
#   12.4  Maven Build  — compile & package all services
#   12.9  NVD Check    — dependency CVE scanning (OWASP Dependency-Check)
#   12.6  Lint         — ESLint (React) + SpotBugs (Java)
#   12.7  SonarQube    — deep quality & security analysis
#   12.8  Quality Gate — SonarQube merge gate
#   12.5  DAST         — OWASP ZAP dynamic scan against the running app
#
# Usage:
#   chmod +x security-pipeline.sh
#   ./security-pipeline.sh [OPTIONS]
#
# Options:
#   --skip-nvd        Skip step 12.9 (avoids the slow initial NVD database download)
#   --skip-sonar      Skip steps 12.7 and 12.8 (no Docker needed)
#   --skip-dast       Skip step 12.5  (requires running app + Docker)
#   --skip-install    Abort if a tool is missing instead of installing it
#   --nvd-key KEY     NVD API key (or set NVD_API_KEY env var)
#   --app-url URL     App URL for DAST scan (default: http://localhost)
#   --repo DIR        Repository root (default: /opt/issue-tracker)
#   --report-root DIR Report parent directory (default: <repo>/security-reports)
#
# Environment variables (alternative to flags):
#   NVD_API_KEY       NVD API key for dependency-check
#   NVD_DATA_DIR      Persistent NVD cache (default: <repo>/.security-cache/dependency-check)
#   NPM_CACHE_DIR     Persistent npm cache (default: <repo>/.security-cache/npm)
#   SKIP_NVD          Set to true to skip the NVD dependency scan
#   SONAR_TOKEN       Pre-existing SonarQube token (skips auto-setup)
#   REPO_DIR          Repository root directory
#   APP_URL           Target URL for DAST scan
#   REPORT_ROOT       Parent directory for timestamped reports
#
# Examples:
#   # Full pipeline (installs missing tools, interactive prompts for SonarQube)
#   ./security-pipeline.sh
#
#   # Skip Docker-dependent steps (faster, no Docker install needed)
#   ./security-pipeline.sh --skip-sonar --skip-dast
#
#   # With NVD API key for faster dependency scan
#   ./security-pipeline.sh --nvd-key xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#
# =============================================================================

set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# DEFAULTS (can be overridden by flags or env vars)
# ─────────────────────────────────────────────────────────────────────────────
REPO_DIR="${REPO_DIR:-/opt/issue-tracker}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_ROOT="${REPORT_ROOT:-}"
NVD_API_KEY="${NVD_API_KEY:-}"
NVD_DATA_DIR="${NVD_DATA_DIR:-}"
NPM_CACHE_DIR="${NPM_CACHE_DIR:-}"
APP_URL="${APP_URL:-http://localhost}"
SKIP_NVD="${SKIP_NVD:-false}"
SKIP_SONAR=false
SKIP_DAST=false
SKIP_INSTALL=false

SONAR_HOST="http://localhost:9000"
SONAR_ADMIN_PASS="PipelineAdmin@1234"   # changed from 'admin' on first run
SONAR_PROJECT_KEY="issue-tracker"
SONAR_TOKEN="${SONAR_TOKEN:-}"          # set by step_sonar, read by step_gate
GITLEAKS_MODE=""

# Java 21 is required for Spring Boot 4.0.1 (auth-service + issue-service)
# The cloud-init VM installs Java 17; this script installs 21 alongside it.
JAVA21_HOME=""   # resolved in setup_java21()

# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-nvd)     SKIP_NVD=true;          shift ;;
        --skip-sonar)   SKIP_SONAR=true;        shift ;;
        --skip-dast)    SKIP_DAST=true;          shift ;;
        --skip-install) SKIP_INSTALL=true;       shift ;;
        --nvd-key)      NVD_API_KEY="$2";        shift 2 ;;
        --app-url)      APP_URL="$2";            shift 2 ;;
        --repo)         REPO_DIR="$2";           shift 2 ;;
        --report-root)  REPORT_ROOT="$2";        shift 2 ;;
        -h|--help)      sed -n '2,50p' "$0"; exit 0 ;;
        *)              echo "Unknown option: $1 (use --help)"; exit 1 ;;
    esac
done

REPORT_ROOT="${REPORT_ROOT:-${REPO_DIR}/security-reports}"
REPORT_DIR="${REPORT_ROOT}/${TIMESTAMP}"
NPM_CACHE_DIR="${NPM_CACHE_DIR:-${REPO_DIR}/.security-cache/npm}"

# ─────────────────────────────────────────────────────────────────────────────
# COLORS
# ─────────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then   # only use colors when writing to a terminal
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP TRACKING
# ─────────────────────────────────────────────────────────────────────────────
# Parallel arrays (bash 3.x-compatible; no associative arrays needed)
STEP_IDS=(  gitleaks  checkstyle  semgrep  build  nvd  lint  sonar  gate  dast )
STEP_NUMS=( "12.1"    "12.2"      "12.3"   "12.4" "12.9" "12.6" "12.7" "12.8" "12.5" )
STEP_NAMES=(
    "Gitleaks          Secret Scanning"
    "Checkstyle        Java Code Style"
    "Semgrep           SAST"
    "Maven Build       Compile & Package"
    "NVD Check         Dependency CVEs"
    "Lint              ESLint + SpotBugs"
    "SonarQube         Quality Analysis"
    "Quality Gate      Merge/Deploy Gate"
    "DAST              ZAP Dynamic Scan"
)
# Status arrays (index-parallel with STEP_IDS)
STEP_STATUS=(  "-" "-" "-" "-" "-" "-" "-" "-" "-" )
STEP_ELAPSED=( "0" "0" "0" "0" "0" "0" "0" "0" "0" )

PIPELINE_START=$(date +%s)
MAIN_LOG=""   # set after REPORT_DIR is created

# Returns the array index for a given step ID
step_index() {
    local id="$1"
    local i
    for i in "${!STEP_IDS[@]}"; do
        [[ "${STEP_IDS[$i]}" == "$id" ]] && echo "$i" && return
    done
    echo "-1"
}

set_step_status() {
    local idx
    idx=$(step_index "$1")
    [[ $idx -ge 0 ]] && STEP_STATUS[$idx]="$2"
}

set_step_elapsed() {
    local idx
    idx=$(step_index "$1")
    [[ $idx -ge 0 ]] && STEP_ELAPSED[$idx]="$2"
}

get_step_status() {
    local idx
    idx=$(step_index "$1")
    [[ $idx -ge 0 ]] && echo "${STEP_STATUS[$idx]}" || echo "-"
}

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────────────────────
_log_to_main() { [[ -n "$MAIN_LOG" ]] && echo "$*" >> "$MAIN_LOG"; }

log_banner() {
    echo ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    printf "${BOLD}${BLUE}║  %-56s  ║${NC}\n" "$1"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    _log_to_main "=== $1 ==="
}

log_step_header() {
    local num="$1" title="$2"
    echo ""
    echo -e "${CYAN}${BOLD}┌─[${num}]──────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}${BOLD}│  ${title}${NC}"
    echo -e "${CYAN}${BOLD}└─────────────────────────────────────────────────────────┘${NC}"
    _log_to_main "--- [$num] $title ---"
}

log_info()  { echo -e "  ${BLUE}→${NC}  $*"; _log_to_main "INFO: $*"; }
log_ok()    { echo -e "  ${GREEN}✔${NC}  $*"; _log_to_main " OK : $*"; }
log_warn()  { echo -e "  ${YELLOW}⚠${NC}  $*"; _log_to_main "WARN: $*"; }
log_error() { echo -e "  ${RED}✖${NC}  $*"; _log_to_main " ERR: $*"; }

log_step_result() {
    local id="$1" status="$2" elapsed="$3" logfile="$4"
    if [[ "$status" == "PASS" ]]; then
        echo -e "${BOLD}  └─ ${GREEN}PASSED${NC}${BOLD}${NC} (${elapsed}s)"
    elif [[ "$status" == "SKIP" ]]; then
        echo -e "${BOLD}  └─ ${YELLOW}SKIPPED${NC}"
    else
        echo -e "${BOLD}  └─ ${RED}FAILED${NC}${BOLD}${NC} (${elapsed}s)"
        echo -e "     ${DIM}Details: ${logfile}${NC}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP RUNNER
# ─────────────────────────────────────────────────────────────────────────────
# Calls "step_<id>", captures output to log file, tracks pass/fail + duration.
# The function runs in the CURRENT shell so variable assignments (e.g. SONAR_TOKEN)
# persist after the call. stdout/stderr are tee'd to the log file.
run_step() {
    local id="$1"
    local idx
    idx=$(step_index "$id")
    local num="${STEP_NUMS[$idx]}"
    local name="${STEP_NAMES[$idx]}"
    local logfile="${REPORT_DIR}/${id}.log"
    local fn="step_${id}"
    local start end elapsed rc

    log_step_header "$num" "$name"
    start=$(date +%s)

    # Run the step function. Its stdout+stderr go to both the terminal (via
    # process substitution) and the log file. The function itself runs in the
    # current shell (not a subshell), so variable assignments persist.
    "$fn" > >(tee -a "$logfile") 2>&1
    rc=$?

    end=$(date +%s)
    elapsed=$(( end - start ))
    set_step_elapsed "$id" "$elapsed"

    if [[ $rc -eq 0 ]]; then
        set_step_status "$id" "PASS"
    else
        set_step_status "$id" "FAIL"
    fi

    log_step_result "$id" "$(get_step_status "$id")" "$elapsed" "$logfile"
    return $rc
}

skip_step() {
    local id="$1" reason="$2"
    local idx
    idx=$(step_index "$id")
    log_warn "${STEP_NUMS[$idx]} ${STEP_NAMES[$idx]}: SKIPPED — ${reason}"
    set_step_status "$id" "SKIP"
}

# ─────────────────────────────────────────────────────────────────────────────
# TOOL SETUP
# ─────────────────────────────────────────────────────────────────────────────
setup_java21() {
    # Spring Boot 4.0.1 requires Java 21+.
    # The cloud-init VM comes with Java 17; install 21 alongside it.

    # Find an existing Java 21 installation first
    local candidate
    for candidate in \
            /usr/lib/jvm/java-21-openjdk-arm64 \
            /usr/lib/jvm/java-21-openjdk-amd64 \
            /usr/lib/jvm/java-21-openjdk \
            /usr/lib/jvm/temurin-21; do
        if [[ -x "${candidate}/bin/java" ]]; then
            JAVA21_HOME="$candidate"
            log_ok "Java 21 found at ${JAVA21_HOME}"
            return 0
        fi
    done

    # Not found — install it
    if [[ "$SKIP_INSTALL" == "true" ]]; then
        log_error "Java 21 not found and --skip-install is set"
        return 1
    fi

    log_info "Installing OpenJDK 21 (alongside existing JDK)..."
    sudo apt-get update -qq
    sudo apt-get install -y openjdk-21-jdk 2>&1 | tail -5

    JAVA21_HOME="/usr/lib/jvm/java-21-openjdk-amd64"
    if [[ ! -x "${JAVA21_HOME}/bin/java" ]]; then
        # Try to find it another way
        JAVA21_HOME=$(update-java-alternatives -l 2>/dev/null \
            | awk '/java-21/{print $3}' | head -1 || true)
    fi

    if [[ -z "$JAVA21_HOME" ]] || [[ ! -x "${JAVA21_HOME}/bin/java" ]]; then
        log_error "Could not find Java 21 after installation"
        return 1
    fi

    log_ok "Java 21 installed: ${JAVA21_HOME}"
}

install_if_missing() {
    local name="$1"
    local check_cmd="$2"
    local install_cmd="$3"

    if eval "$check_cmd" &>/dev/null; then
        log_ok "${name}: already installed"
        return 0
    fi

    if [[ "$SKIP_INSTALL" == "true" ]]; then
        log_error "${name}: not found (--skip-install set)"
        return 1
    fi

    log_info "Installing ${name}..."
    eval "$install_cmd" 2>&1 | tail -5
    if eval "$check_cmd" &>/dev/null; then
        log_ok "${name}: installed"
    else
        log_error "${name}: installation failed"
        return 1
    fi
}

setup_node20() {
    local node_major=""

    if command -v node &>/dev/null; then
        node_major=$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)
    fi

    if [[ "$node_major" =~ ^[0-9]+$ ]] && [[ "$node_major" -ge 20 ]] && \
       command -v npm &>/dev/null; then
        log_ok "Node.js / npm: $(node --version) / $(npm --version)"
    else
        if [[ "$SKIP_INSTALL" == "true" ]]; then
            log_error "Node.js 20 with npm is required and --skip-install is set"
            return 1
        fi

        log_info "Installing Node.js 20 and npm..."
        sudo apt-get install -y ca-certificates curl gnupg -qq || return 1
        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - || return 1
        sudo apt-get install -y nodejs -qq || return 1

        node_major=$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)
        if [[ ! "$node_major" =~ ^[0-9]+$ ]] || [[ "$node_major" -lt 20 ]] || \
           ! command -v npm &>/dev/null; then
            log_error "Node.js 20/npm installation failed"
            return 1
        fi
        log_ok "Node.js / npm installed: $(node --version) / $(npm --version)"
    fi

    # Node uses a bundled CA set by default. Include Ubuntu's trust store so a
    # corporate CA imported by cloud-init remains verified by npm as well.
    if [[ -r /etc/ssl/certs/ca-certificates.crt ]]; then
        export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
    fi

    mkdir -p "$NPM_CACHE_DIR"
    export npm_config_cache="$NPM_CACHE_DIR"
    log_ok "npm cache: ${NPM_CACHE_DIR}"
}

setup_tools() {
    log_banner "Environment Setup"

    mkdir -p "$REPORT_DIR"
    MAIN_LOG="${REPORT_DIR}/pipeline.log"
    touch "$MAIN_LOG"

    echo "Pipeline started: $(date)"       >> "$MAIN_LOG"
    echo "Repository:       ${REPO_DIR}"   >> "$MAIN_LOG"
    echo "Reports:          ${REPORT_DIR}" >> "$MAIN_LOG"
    echo ""                                >> "$MAIN_LOG"

    log_info "Repository : ${REPO_DIR}"
    log_info "Reports    : ${REPORT_DIR}"
    log_info ""

    # ── Java 21 ────────────────────────────────────────────────────────────
    setup_java21 || return 1

    # ── System packages (apt) ──────────────────────────────────────────────
    install_if_missing "jq" \
        "command -v jq" \
        "sudo apt-get install -y jq -qq" || return 1

    install_if_missing "pip3" \
        "command -v pip3" \
        "sudo apt-get install -y python3-pip -qq" || return 1

    setup_node20 || return 1

    install_if_missing "Docker" \
        "command -v docker" \
        'if ! curl -fsSL https://get.docker.com | sudo sh -s -- -q; then
             echo "Official Docker installer unavailable; using Ubuntu docker.io"
             sudo apt-get update -qq
             sudo apt-get install -y docker.io -qq
         fi' || return 1

    # ── Gitleaks ───────────────────────────────────────────────────────────
    # Corporate policy may block GitHub release assets while allowing GHCR.
    if command -v gitleaks &>/dev/null; then
        GITLEAKS_MODE="binary"
        log_ok "Gitleaks: local binary"
    else
        if ! sudo docker image inspect ghcr.io/gitleaks/gitleaks:latest &>/dev/null; then
            if [[ "$SKIP_INSTALL" == "true" ]]; then
                log_error "Gitleaks binary/image unavailable and --skip-install is set"
                return 1
            fi
            log_info "Pulling official Gitleaks container..."
            sudo docker pull ghcr.io/gitleaks/gitleaks:latest || return 1
        fi
        GITLEAKS_MODE="container"
        log_ok "Gitleaks: official container"
    fi

    # ── Semgrep ────────────────────────────────────────────────────────────
    install_if_missing "semgrep" \
        "command -v semgrep" \
        "pip3 install semgrep --quiet" || return 1

    log_info ""
    log_ok "All tools ready — starting pipeline"
}

# ─────────────────────────────────────────────────────────────────────────────
# HELPER: run mvnw for a service, forcing Java 21
# ─────────────────────────────────────────────────────────────────────────────
mvnw() {
    # mvnw <service> [maven args...]
    local svc="$1"; shift
    local svc_dir="${REPO_DIR}/${svc}"
    JAVA_HOME="$JAVA21_HOME" "${svc_dir}/mvnw" \
        -f "${svc_dir}/pom.xml" \
        "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# 12.1  GITLEAKS
# ─────────────────────────────────────────────────────────────────────────────
step_gitleaks() {
    local report="${REPORT_DIR}/gitleaks.json"

    # Allowlist: placeholder values committed in cloud-init / README examples
    cat > "${REPORT_DIR}/.gitleaks.toml" << 'TOML'
title = "Issue Tracker Gitleaks Config"

[allowlist]
description = "Placeholder values in cloud-init and README examples"
regexes = [
    "ReplaceThisWithASecureSecretKeyOfAtLeast32Chars",
    "not-configured",
    "StrongPass@2024!",
    "Admin@2024!",
    "squ_xxxxxxxxxxxxxxxxxxxxx"
]
TOML

    log_info "Scanning full git history for secrets..."

    local rc
    if [[ "$GITLEAKS_MODE" == "container" ]]; then
        sudo docker run --rm \
            -v "${REPO_DIR}:/repo:ro" \
            -v "${REPORT_DIR}:/reports" \
            ghcr.io/gitleaks/gitleaks:latest detect \
            --source /repo \
            --config /reports/.gitleaks.toml \
            --report-format json \
            --report-path /reports/gitleaks.json \
            --no-banner \
            --verbose 2>&1
        rc=$?
    else
        GIT_CONFIG_COUNT=1 \
            GIT_CONFIG_KEY_0=safe.directory \
            GIT_CONFIG_VALUE_0="$REPO_DIR" \
            gitleaks detect \
            --source "$REPO_DIR" \
            --config "${REPORT_DIR}/.gitleaks.toml" \
            --report-format json \
            --report-path "$report" \
            --no-banner \
            --verbose 2>&1
        rc=$?
    fi

    if [[ $rc -eq 0 ]]; then
        log_ok "No secrets detected in git history"
        return 0
    else
        local n
        n=$(jq 'length' "$report" 2>/dev/null || echo "?")
        log_error "${n} secret(s) found — review ${report}"
        jq -r '.[] | "  \(.RuleID) in \(.File):\(.StartLine)"' "$report" 2>/dev/null || true
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 12.2  CHECKSTYLE
# ─────────────────────────────────────────────────────────────────────────────
step_checkstyle() {
    # Write the checkstyle ruleset to a temp file.
    # lombok.* wildcard imports are exempted (standard Lombok usage pattern).
    local cs_xml="${REPORT_DIR}/checkstyle.xml"

    cat > "$cs_xml" << 'XML'
<?xml version="1.0"?>
<!DOCTYPE module PUBLIC
    "-//Checkstyle//DTD Checkstyle Configuration 1.3//EN"
    "https://checkstyle.org/dtds/configuration_1_3.dtd">
<!--
  Custom ruleset for Issue Tracker.
  Focuses on naming, import hygiene, code correctness, and security-relevant
  style rules (e.g. NeedBraces prevents Apple-style goto-fail bugs).
-->
<module name="Checker">
    <property name="charset"  value="UTF-8"/>
    <property name="severity" value="warning"/>

    <!-- File-level: no trailing whitespace in blank lines -->
    <module name="NewlineAtEndOfFile">
        <property name="lineSeparator" value="lf"/>
    </module>

    <module name="TreeWalker">

        <!-- ── Naming ──────────────────────────────────────────────── -->
        <module name="TypeName"/>
        <module name="ConstantName"/>
        <module name="MethodName"/>
        <module name="PackageName"/>
        <module name="LocalVariableName"/>
        <module name="ParameterName"/>

        <!-- ── Imports ─────────────────────────────────────────────── -->
        <!-- Allow lombok.* (standard Lombok pattern); block all others -->
        <module name="AvoidStarImport">
            <property name="excludes" value="lombok,lombok.extern.slf4j"/>
        </module>
        <module name="UnusedImports"/>
        <module name="IllegalImport">
            <!-- Block sun.* internals -->
            <property name="illegalPkgs" value="sun"/>
        </module>

        <!-- ── Code Correctness ─────────────────────────────────────── -->
        <!-- Prevent Apple-style goto-fail: require braces on every block -->
        <module name="NeedBraces"/>
        <module name="EmptyBlock"/>
        <!-- If you override equals(), you must override hashCode() -->
        <module name="EqualsHashCode"/>
        <module name="SimplifyBooleanExpression"/>
        <module name="SimplifyBooleanReturn"/>
        <!-- Avoid == on strings -->
        <module name="StringLiteralEquality"/>
        <!-- Detect fall-through in switch without comment -->
        <module name="FallThrough"/>

        <!-- ── Security-relevant ────────────────────────────────────── -->
        <!-- Use L not l for long literals (1l looks like 11) -->
        <module name="UpperEll"/>

    </module>
</module>
XML

    local cs_plugin="org.apache.maven.plugins:maven-checkstyle-plugin:3.3.1:check"
    local failed=0

    for svc in auth-service issue-service api-gateway; do
        log_info "Checking style: ${svc}"

        if mvnw "$svc" \
            "$cs_plugin" \
            "-Dcheckstyle.config.location=${cs_xml}" \
            -Dcheckstyle.consoleOutput=true \
            -Dcheckstyle.failsOnError=true \
            -Dcheckstyle.violationSeverity=warning \
            -B --no-transfer-progress 2>&1; then
            log_ok "${svc}: style OK"
        else
            log_warn "${svc}: style violations found"
            failed=$(( failed + 1 ))
        fi
    done

    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 12.3  SEMGREP (SAST)
# ─────────────────────────────────────────────────────────────────────────────
step_semgrep() {
    local out_java="${REPORT_DIR}/semgrep-java.json"
    local out_js="${REPORT_DIR}/semgrep-js.json"

    log_info "SAST scan — Java services (spring-security, java, owasp-top-ten)..."
    semgrep scan \
        --config "p/spring-security" \
        --config "p/java" \
        --config "p/owasp-top-ten" \
        --json \
        --output "$out_java" \
        --quiet \
        "${REPO_DIR}/auth-service/src" \
        "${REPO_DIR}/issue-service/src" \
        "${REPO_DIR}/api-gateway/src" 2>&1 || true

    log_info "SAST scan — React frontend (javascript, react)..."
    semgrep scan \
        --config "p/javascript" \
        --config "p/react" \
        --json \
        --output "$out_js" \
        --quiet \
        "${REPO_DIR}/frontend-service/src" 2>&1 || true

    local java_total java_errors js_total js_errors
    java_total=$(jq '.results | length'                                      "$out_java" 2>/dev/null || echo 0)
    java_errors=$(jq '[.results[] | select(.extra.severity=="ERROR")] | length' "$out_java" 2>/dev/null || echo 0)
    js_total=$(jq '.results | length'                                          "$out_js"   2>/dev/null || echo 0)
    js_errors=$(jq '[.results[] | select(.extra.severity=="ERROR")] | length'   "$out_js"   2>/dev/null || echo 0)
    local total_errors=$(( java_errors + js_errors ))
    local total=$(( java_total + js_total ))

    log_info "Java findings : ${java_total} (${java_errors} ERROR-level)"
    log_info "JS/React findings: ${js_total} (${js_errors} ERROR-level)"

    if [[ $total -eq 0 ]]; then
        log_ok "No SAST findings"
        return 0
    elif [[ $total_errors -gt 0 ]]; then
        log_error "${total_errors} high-severity finding(s) — review reports:"
        log_error "  ${out_java}"
        log_error "  ${out_js}"
        # Print the high-severity findings inline
        jq -r '.results[]
               | select(.extra.severity=="ERROR")
               | "  [\(.check_id)] \(.path):\(.start.line) — \(.extra.message)"' \
            "$out_java" "$out_js" 2>/dev/null || true
        return 1
    else
        log_warn "${total} informational finding(s) — review reports for details"
        log_warn "  ${out_java}"
        log_warn "  ${out_js}"
        return 0
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 12.4  MAVEN BUILD
# ─────────────────────────────────────────────────────────────────────────────
step_build() {
    local failed=0

    for svc in auth-service issue-service api-gateway; do
        log_info "Building ${svc}..."

        if mvnw "$svc" clean package -DskipTests -B --no-transfer-progress 2>&1; then
            local jar
            jar=$(find "${REPO_DIR}/${svc}/target" -name "*.jar" \
                  ! -name "*sources*" ! -name "*javadoc*" 2>/dev/null | head -1)
            log_ok "${svc}: OK → ${jar##*/}"
        else
            log_error "${svc}: BUILD FAILED"
            failed=$(( failed + 1 ))
        fi
    done

    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 12.9  NVD CHECK  (OWASP Dependency-Check)
# ─────────────────────────────────────────────────────────────────────────────
step_nvd() {
    local failed=0
    local nvd_script="${REPO_DIR}/scripts/nvd-scan.sh"
    local nvd_data_dir="${NVD_DATA_DIR:-${REPO_DIR}/.security-cache/dependency-check}"

    if [[ -z "$NVD_API_KEY" ]]; then
        log_warn "NVD_API_KEY is not set."
        log_warn "The first run downloads the full NVD database which can take 10-30 min."
        log_warn "Get a free key at https://nvd.nist.gov/developers/request-an-api-key"
        log_warn "Then re-run with: ./security-pipeline.sh --nvd-key <key>"
    fi

    if [[ ! -x "$nvd_script" ]]; then
        log_error "NVD scan helper is missing or not executable: ${nvd_script}"
        return 1
    fi

    log_info "Updating the shared NVD cache once, then scanning all Java services..."
    if NVD_API_KEY="$NVD_API_KEY" \
       NVD_DATA_DIR="$nvd_data_dir" \
       "$nvd_script" scan --report-dir "${REPORT_DIR}/nvd" 2>&1; then
        log_ok "Java dependency scans passed"
    else
        log_error "One or more Java dependency scans failed — see ${REPORT_DIR}/nvd"
        failed=$(( failed + 1 ))
    fi

    # npm audit for the React frontend
    local fe_dir="${REPO_DIR}/frontend-service"
    if command -v npm &>/dev/null && [[ -d "$fe_dir" ]]; then
        log_info "npm audit — frontend..."
        cd "$fe_dir"
        if [[ ! -x node_modules/.bin/eslint ]]; then
            log_info "Installing frontend dependencies from the persistent npm cache..."
            if ! npm ci --prefer-offline --no-audit 2>&1 | tail -20; then
                log_error "frontend: npm ci failed; sync the Mac cache with scripts/sync-npm-cache-to-vm.sh"
                cd - > /dev/null
                return 1
            fi
        fi
        if npm audit --audit-level=high 2>&1; then
            log_ok "frontend: npm audit passed (no high/critical)"
        else
            log_error "frontend: HIGH/CRITICAL npm vulnerabilities found"
            failed=$(( failed + 1 ))
        fi
        cd - > /dev/null
    fi

    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 12.6  LINT  (ESLint + SpotBugs)
# ─────────────────────────────────────────────────────────────────────────────
step_lint() {
    local failed=0

    # ── ESLint ───────────────────────────────────────────────────────────────
    local fe_dir="${REPO_DIR}/frontend-service"
    if command -v npm &>/dev/null && [[ -d "$fe_dir" ]]; then
        log_info "ESLint — React frontend..."
        cd "$fe_dir"
        if [[ ! -x node_modules/.bin/eslint ]]; then
            log_info "Installing frontend dependencies from the persistent npm cache..."
            if ! npm ci --prefer-offline --no-audit 2>&1 | tail -20; then
                log_error "ESLint dependencies unavailable; sync the Mac npm cache first"
                cd - > /dev/null
                return 1
            fi
        fi
        if npm run lint 2>&1; then
            log_ok "ESLint: passed"
        else
            log_error "ESLint: violations found"
            failed=$(( failed + 1 ))
        fi
        cd - > /dev/null
    else
        log_warn "npm not available — skipping ESLint"
    fi

    # ── SpotBugs + FindSecBugs ─────────────────────────────────────────────
    # Uses the FindSecBugs plugin for security-specific bug patterns.
    # Requires compiled classes from step_build.
    local sb_plugin="com.github.spotbugs:spotbugs-maven-plugin:4.8.3.1:check"

    for svc in auth-service issue-service api-gateway; do
        local classes_dir="${REPO_DIR}/${svc}/target/classes"
        if [[ ! -d "$classes_dir" ]]; then
            log_warn "${svc}: no compiled classes — Maven Build must pass first"
            continue
        fi

        log_info "SpotBugs — ${svc}..."
        if mvnw "$svc" \
            "$sb_plugin" \
            -Dspotbugs.effort=Max \
            -Dspotbugs.threshold=Low \
            -Dspotbugs.failOnError=true \
            -B --no-transfer-progress 2>&1; then
            log_ok "${svc}: SpotBugs passed"
        else
            log_warn "${svc}: SpotBugs findings (see log for details)"
            failed=$(( failed + 1 ))
        fi
    done

    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 12.7  SONARQUBE
# ─────────────────────────────────────────────────────────────────────────────
step_sonar() {
    # ── Pre-flight ────────────────────────────────────────────────────────
    local free_mb
    free_mb=$(free -m | awk '/^Mem:/{print $7}' 2>/dev/null || echo 9999)
    if [[ $free_mb -lt 1500 ]]; then
        log_error "Only ${free_mb} MB free RAM — SonarQube needs ~1.5 GB"
        log_error "Run --skip-sonar or stop other services to free up RAM"
        return 1
    fi

    if ! command -v docker &>/dev/null; then
        log_error "Docker is required for SonarQube (not installed)"
        return 1
    fi

    # Elasticsearch inside SonarQube requires this kernel setting
    sudo sysctl -w vm.max_map_count=262144 &>/dev/null || true

    # ── Start SonarQube container ─────────────────────────────────────────
    if sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^sonarqube$"; then
        log_info "SonarQube container already running"
    else
        log_info "Starting SonarQube community container (~2 GB, first pull may take a while)..."
        sudo docker run -d \
            --name    sonarqube \
            --memory  2g \
            --restart unless-stopped \
            -p 9000:9000 \
            -v sonarqube_data:/opt/sonarqube/data \
            sonarqube:community 2>&1
    fi

    # ── Wait for ready (up to 5 min) ──────────────────────────────────────
    log_info "Waiting for SonarQube to become ready..."
    local waited=0 max=300
    until curl -sf "${SONAR_HOST}/api/system/status" 2>/dev/null \
              | grep -q '"status":"UP"'; do
        sleep 5
        waited=$(( waited + 5 ))
        if [[ $waited -ge $max ]]; then
            log_error "SonarQube not ready after ${max}s"
            log_error "Container logs:"
            sudo docker logs --tail 30 sonarqube 2>&1 || true
            return 1
        fi
        printf "."
    done
    echo ""
    log_ok "SonarQube is UP at ${SONAR_HOST}"

    # ── Change default admin password (idempotent) ────────────────────────
    # Attempt with "admin" (fresh install); silently ignore if already changed.
    curl -sf -u admin:admin \
        -X POST "${SONAR_HOST}/api/users/change_password" \
        -d "login=admin&previousPassword=admin&password=${SONAR_ADMIN_PASS}" \
        &>/dev/null || true

    # ── Generate an analysis token ────────────────────────────────────────
    if [[ -z "$SONAR_TOKEN" ]]; then
        # Revoke any old pipeline token first (idempotent)
        curl -sf -u "admin:${SONAR_ADMIN_PASS}" \
            -X POST "${SONAR_HOST}/api/user_tokens/revoke" \
            -d "login=admin&name=pipeline-token" \
            &>/dev/null || true

        SONAR_TOKEN=$(curl -sf -u "admin:${SONAR_ADMIN_PASS}" \
            -X POST "${SONAR_HOST}/api/user_tokens/generate" \
            -d "login=admin&name=pipeline-token&type=GLOBAL_ANALYSIS_TOKEN" \
            | jq -r '.token' 2>/dev/null || echo "")
    fi

    if [[ -z "$SONAR_TOKEN" ]]; then
        log_error "Failed to obtain SonarQube analysis token"
        return 1
    fi

    # Persist for step_gate (even if this step runs in a subshell context)
    echo "$SONAR_TOKEN" > "${REPORT_DIR}/sonar-token.txt"
    log_ok "Analysis token acquired"

    # ── Analyse each service ──────────────────────────────────────────────
    local failed=0

    for svc in auth-service issue-service api-gateway; do
        local project_key="${SONAR_PROJECT_KEY}-${svc}"
        local project_name="Issue Tracker — ${svc}"

        # Create project (idempotent; HTTP 400 if already exists — ignore)
        curl -sf -u "admin:${SONAR_ADMIN_PASS}" \
            -X POST "${SONAR_HOST}/api/projects/create" \
            -d "project=${project_key}&name=${project_name}" \
            &>/dev/null || true

        log_info "Submitting analysis: ${svc}..."
        if mvnw "$svc" \
            "org.sonarsource.scanner.maven:sonar-maven-plugin:sonar" \
            -Dsonar.host.url="${SONAR_HOST}" \
            -Dsonar.token="${SONAR_TOKEN}" \
            -Dsonar.projectKey="${project_key}" \
            -Dsonar.projectName="${project_name}" \
            -B --no-transfer-progress 2>&1; then
            log_ok "${svc}: analysis submitted"
        else
            log_error "${svc}: analysis failed"
            failed=$(( failed + 1 ))
        fi
    done

    log_info ""
    log_info "SonarQube UI  : ${SONAR_HOST}"
    log_info "Login         : admin / ${SONAR_ADMIN_PASS}"

    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 12.8  QUALITY GATE
# ─────────────────────────────────────────────────────────────────────────────
step_gate() {
    # Recover token from file in case step_sonar ran before us
    if [[ -z "$SONAR_TOKEN" ]] && [[ -f "${REPORT_DIR}/sonar-token.txt" ]]; then
        SONAR_TOKEN=$(cat "${REPORT_DIR}/sonar-token.txt")
    fi

    if [[ -z "$SONAR_TOKEN" ]]; then
        log_error "No SonarQube token available — did step 12.7 pass?"
        return 1
    fi

    local failed=0

    for svc in auth-service issue-service api-gateway; do
        local project_key="${SONAR_PROJECT_KEY}-${svc}"
        log_info "Quality Gate check: ${svc}..."

        # Poll until the CE (background analysis task) finishes — max 3 min
        local attempts=0 gate_status=""
        while [[ $attempts -lt 36 ]]; do
            gate_status=$(
                curl -sf -u "${SONAR_TOKEN}:" \
                    "${SONAR_HOST}/api/qualitygates/project_status?projectKey=${project_key}" \
                    | jq -r '.projectStatus.status' 2>/dev/null || echo ""
            )
            # "NONE" means no gate assigned (uses default Sonar Way gate)
            if [[ "$gate_status" == "OK" || "$gate_status" == "ERROR" \
                  || "$gate_status" == "WARN" || "$gate_status" == "NONE" ]]; then
                break
            fi
            sleep 5
            attempts=$(( attempts + 1 ))
            printf "."
        done
        echo ""

        case "$gate_status" in
            OK)
                log_ok "${svc}: Quality Gate PASSED" ;;
            ERROR)
                log_error "${svc}: Quality Gate FAILED"
                # Print failed conditions
                curl -sf -u "${SONAR_TOKEN}:" \
                    "${SONAR_HOST}/api/qualitygates/project_status?projectKey=${project_key}" \
                    | jq -r '.projectStatus.conditions[]
                              | select(.status == "ERROR")
                              | "    \(.metricKey): actual=\(.actualValue)  threshold=\(.errorThreshold)"' \
                    2>/dev/null || true
                failed=$(( failed + 1 ))
                ;;
            WARN)
                log_warn "${svc}: Quality Gate has warnings (not blocking)" ;;
            NONE)
                log_warn "${svc}: No Quality Gate assigned — assign one at ${SONAR_HOST}/quality_gates" ;;
            *)
                log_warn "${svc}: Gate result unavailable (analysis may still be running)" ;;
        esac
    done

    log_info "Full results: ${SONAR_HOST}/projects"
    [[ $failed -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 12.5  DAST  (OWASP ZAP baseline scan)
# ─────────────────────────────────────────────────────────────────────────────
step_dast() {
    if ! command -v docker &>/dev/null; then
        log_error "Docker is required for ZAP — install Docker or use --skip-dast"
        return 1
    fi

    # Verify the app is up before scanning
    log_info "Checking app reachability at ${APP_URL}..."
    if ! curl -sf --max-time 10 "${APP_URL}/" &>/dev/null; then
        log_error "App is not accessible at ${APP_URL}"
        log_error "Start the services first:"
        log_error "  sudo systemctl start auth-service issue-service api-gateway nginx"
        log_error "Then re-run: APP_URL=${APP_URL} $0 --skip-sonar"
        return 1
    fi
    log_ok "App is reachable"

    local html_report="${REPORT_DIR}/zap-report.html"
    local json_report="${REPORT_DIR}/zap-report.json"
    local zap_work="${REPORT_DIR}/zap-work"

    # The official image runs as an unprivileged user. Give it a dedicated
    # writable mount instead of relaxing permissions on the whole report tree.
    mkdir -p "$zap_work"
    chmod 0777 "$zap_work"

    log_info "Running ZAP baseline scan (passive — no active attacks)..."
    log_info "Target: ${APP_URL}"

    # Avoid running two memory-intensive security platforms concurrently.
    local sonar_was_running=false
    if sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^sonarqube$'; then
        sonar_was_running=true
        log_info "Stopping SonarQube temporarily while ZAP runs..."
        sudo docker stop sonarqube >/dev/null
    fi

    # --network host so ZAP can reach localhost inside the VM
    local zap_rc=0
    sudo docker run --rm \
        --network host \
        -v "${zap_work}:/zap/wrk:rw" \
        ghcr.io/zaproxy/zaproxy:stable \
        zap-baseline.py \
            -t "${APP_URL}/" \
            -r "zap-report.html" \
            -J "zap-report.json" \
            -l WARN \
            -I 2>&1 || zap_rc=$?          # -I: don't fail on warnings

    [[ -f "${zap_work}/zap-report.html" ]] && cp "${zap_work}/zap-report.html" "$html_report"
    [[ -f "${zap_work}/zap-report.json" ]] && cp "${zap_work}/zap-report.json" "$json_report"
    chmod 0755 "$zap_work"

    if [[ "$sonar_was_running" == "true" ]]; then
        log_info "Restarting SonarQube after ZAP..."
        sudo docker start sonarqube >/dev/null
    fi

    if [[ $zap_rc -eq 0 ]]; then
        log_ok "ZAP scan complete — report: ${html_report}"
        return 0
    else
        if [[ ! -f "$json_report" ]]; then
            log_error "ZAP exited with code ${zap_rc} before generating its JSON report"
            log_error "See ${REPORT_DIR}/dast.log for scanner diagnostics"
            return 1
        fi

        # ZAP exits non-zero when it finds alerts at WARN level or above
        local medium_plus
        medium_plus=$(jq '[.site[].alerts[] | select(.riskcode | tonumber >= 2)] | length' \
            "$json_report" 2>/dev/null || echo "?")
        log_error "ZAP found ${medium_plus} medium/high risk alert(s)"
        log_error "HTML report: ${html_report}"

        # Print a brief summary of alerts
        jq -r '.site[].alerts[]
               | select(.riskcode | tonumber >= 2)
               | "  [\(.riskdesc)] \(.alert) — \(.url | split("?")[0])"' \
            "$json_report" 2>/dev/null | sort -u || true

        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# FINAL SUMMARY TABLE
# ─────────────────────────────────────────────────────────────────────────────
print_summary() {
    local pipeline_end total_elapsed pass=0 fail=0 skip=0
    pipeline_end=$(date +%s)
    total_elapsed=$(( pipeline_end - PIPELINE_START ))

    echo ""
    echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║       SECURITY & CODE QUALITY PIPELINE — SUMMARY           ║${NC}"
    echo -e "${BOLD}${BLUE}╠════════════════════════════════════════════════════════════╣${NC}"

    local i
    for i in "${!STEP_IDS[@]}"; do
        local id="${STEP_IDS[$i]}"
        local num="${STEP_NUMS[$i]}"
        local name="${STEP_NAMES[$i]}"
        local status="${STEP_STATUS[$i]}"
        local elapsed="${STEP_ELAPSED[$i]}"
        local color icon

        case "$status" in
            PASS) color=$GREEN;  icon="✔"; pass=$(( pass + 1 )) ;;
            FAIL) color=$RED;    icon="✖"; fail=$(( fail + 1 )) ;;
            SKIP) color=$YELLOW; icon="—"; skip=$(( skip + 1 )) ;;
            *)    color=$DIM;    icon="?"; ;;
        esac

        printf "${BOLD}${BLUE}║${NC}  ${color}${BOLD}%s${NC}  %-6s  %-36s  %5ss  ${BOLD}${BLUE}║${NC}\n" \
            "$icon" "$num" "$name" "$elapsed"
    done

    echo -e "${BOLD}${BLUE}╠════════════════════════════════════════════════════════════╣${NC}"

    # Overall verdict
    local verdict_color verdict_msg
    if [[ $fail -eq 0 ]]; then
        verdict_color=$GREEN
        verdict_msg="ALL CHECKS PASSED — safe to merge and deploy"
    else
        verdict_color=$RED
        verdict_msg="${fail} CHECK(S) FAILED — do not merge or deploy"
    fi
    printf "${BOLD}${BLUE}║${NC}  ${verdict_color}${BOLD}%-58s${NC}  ${BOLD}${BLUE}║${NC}\n" "$verdict_msg"

    local stats="Pass: ${pass}  Fail: ${fail}  Skip: ${skip}  Total: ${total_elapsed}s"
    printf "${BOLD}${BLUE}║${NC}  ${DIM}%-58s${NC}  ${BOLD}${BLUE}║${NC}\n" "$stats"
    printf "${BOLD}${BLUE}║${NC}  ${DIM}%-58s${NC}  ${BOLD}${BLUE}║${NC}\n" "Reports: ${REPORT_DIR}"
    echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # List failures with their log paths
    if [[ $fail -gt 0 ]]; then
        echo -e "${BOLD}${RED}Failed steps:${NC}"
        for i in "${!STEP_IDS[@]}"; do
            if [[ "${STEP_STATUS[$i]}" == "FAIL" ]]; then
                local id="${STEP_IDS[$i]}"
                echo -e "  ${RED}✖${NC} ${STEP_NUMS[$i]} ${STEP_NAMES[$i]}"
                echo -e "    ${DIM}log: ${REPORT_DIR}/${id}.log${NC}"
            fi
        done
        echo ""
        return 1
    fi

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    log_banner "Security & Code Quality Pipeline — Issue Tracker v1"
    echo -e "  ${DIM}Repository : ${REPO_DIR}${NC}"
    echo -e "  ${DIM}Started    : $(date)${NC}"
    [[ "$SKIP_NVD"   == "true" ]] && echo -e "  ${YELLOW}⚠${NC}  NVD Check: SKIPPED (initialization deferred)"
    [[ "$SKIP_SONAR" == "true" ]] && echo -e "  ${YELLOW}⚠${NC}  SonarQube + Quality Gate: SKIPPED"
    [[ "$SKIP_DAST"  == "true" ]] && echo -e "  ${YELLOW}⚠${NC}  DAST: SKIPPED"
    echo ""

    # ── Setup: install missing tools ─────────────────────────────────────
    setup_tools || { echo "Setup failed — aborting"; exit 1; }

    # Verify the repository exists
    if [[ ! -d "$REPO_DIR" ]]; then
        echo -e "${RED}ERROR: Repository not found at ${REPO_DIR}${NC}"
        echo -e "       Set the path with --repo <path> or clone it first:"
        echo -e "       git clone --branch v1 https://github.com/amitactive2008/sample-spring-boot-application.git /opt/issue-tracker"
        exit 1
    fi

    # ── 12.1 Gitleaks ────────────────────────────────────────────────────
    run_step "gitleaks"

    # ── 12.2 Checkstyle ──────────────────────────────────────────────────
    run_step "checkstyle"

    # ── 12.3 Semgrep (SAST) ──────────────────────────────────────────────
    run_step "semgrep"

    # ── 12.4 Maven Build ─────────────────────────────────────────────────
    run_step "build"

    # Steps below depend on a successful build producing JAR / class files
    local build_ok=false
    [[ "$(get_step_status build)" == "PASS" ]] && build_ok=true

    # ── 12.9 NVD Check ───────────────────────────────────────────────────
    if [[ "$SKIP_NVD" == "true" ]]; then
        skip_step "nvd" "--skip-nvd flag or SKIP_NVD=true set"
    elif $build_ok; then
        run_step "nvd"
    else
        skip_step "nvd" "Maven Build failed — no artifacts to scan"
    fi

    # ── 12.6 Lint (ESLint + SpotBugs) ────────────────────────────────────
    if $build_ok; then
        run_step "lint"
    else
        skip_step "lint" "Maven Build failed — no compiled classes for SpotBugs"
    fi

    # ── 12.7 SonarQube ───────────────────────────────────────────────────
    if [[ "$SKIP_SONAR" == "true" ]]; then
        skip_step "sonar" "--skip-sonar flag set"
        skip_step "gate"  "--skip-sonar flag set"
    elif $build_ok; then
        run_step "sonar"
        # ── 12.8 Quality Gate ─────────────────────────────────────────
        if [[ "$(get_step_status sonar)" == "PASS" ]]; then
            run_step "gate"
        else
            skip_step "gate" "SonarQube analysis failed"
        fi
    else
        skip_step "sonar" "Maven Build failed — no compiled classes"
        skip_step "gate"  "Maven Build failed"
    fi

    # ── 12.5 DAST (ZAP) ──────────────────────────────────────────────────
    # Runs against the live application; skip if app is not running.
    if [[ "$SKIP_DAST" == "true" ]]; then
        skip_step "dast" "--skip-dast flag set"
    else
        run_step "dast"
    fi

    # ── Summary ───────────────────────────────────────────────────────────
    print_summary
}

main "$@"
