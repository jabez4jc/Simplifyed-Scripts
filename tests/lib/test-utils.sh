#!/usr/bin/env bash
# Test utilities — assertions, reporting, mocking, SSH helpers
# Source this from any test suite: source "$(dirname "$0")/../lib/test-utils.sh"

set -o pipefail

TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILURES=()
SUITE_NAME=""

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Lifecycle ──────────────────────────────────────────

suite_start() {
    SUITE_NAME="${1:-Unnamed Suite}"
    TESTS_TOTAL=0; TESTS_PASSED=0; TESTS_FAILED=0; TESTS_SKIPPED=0; FAILURES=()
    printf "\n${CYAN}═══ %s ═══${NC}\n" "$SUITE_NAME"
}

test_start() {
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
}

test_pass() {
    printf "  ${GREEN}✓${NC} %s\n" "$1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_fail() {
    local msg="${1:-}"
    printf "  ${RED}✗${NC} %s\n" "$msg"
    FAILURES+=("${SUITE_NAME}: ${msg}")
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

test_skip() {
    printf "  ${YELLOW}⊘${NC} %s\n" "$1"
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
}

suite_report() {
    local color="$GREEN"
    [[ $TESTS_FAILED -gt 0 ]] && color="$RED"
    [[ $TESTS_FAILED -eq 0 && $TESTS_SKIPPED -gt 0 ]] && color="$YELLOW"
    printf "${color}${BOLD}%s${NC}\n" "$SUITE_NAME: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_SKIPPED skipped / $TESTS_TOTAL total"
    return $TESTS_FAILED
}

# ── Assertions ─────────────────────────────────────────

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [[ "$actual" == "$expected" ]]; then
        test_pass "${msg:-assert_eq: $expected == $actual}"
    else
        test_fail "${msg:-assert_eq: expected '$expected', got '$actual'}"
    fi
}

assert_neq() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [[ "$actual" != "$expected" ]]; then
        test_pass "${msg:-assert_neq: $expected != $actual}"
    else
        test_fail "${msg:-assert_neq: expected != '$expected', got '$actual'}"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    if [[ "$haystack" == *"$needle"* ]]; then
        test_pass "${msg:-assert_contains: found '$needle'}"
    else
        test_fail "${msg:-assert_contains: missing '$needle' in '$haystack'}"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    if [[ "$haystack" != *"$needle"* ]]; then
        test_pass "${msg:-assert_not_contains: absent '$needle'}"
    else
        test_fail "${msg:-assert_not_contains: unexpected '$needle' in '$haystack'}"
    fi
}

assert_exit_code() {
    local expected="$1" msg="${3:-}"
    shift 2
    local actual=0
    "$@" 2>/dev/null || actual=$?
    if [[ "$actual" -eq "$expected" ]]; then
        test_pass "${msg:-exit code $expected: $*}"
    else
        test_fail "${msg:-exit code: expected $expected, got $actual: $*}"
    fi
}

assert_file_exists() {
    local file="$1" msg="${2:-}"
    if [[ -f "$file" ]]; then
        test_pass "${msg:-file exists: $file}"
    else
        test_fail "${msg:-file not found: $file}"
    fi
}

assert_dir_exists() {
    local dir="$1" msg="${2:-}"
    if [[ -d "$dir" ]]; then
        test_pass "${msg:-dir exists: $dir}"
    else
        test_fail "${msg:-dir not found: $dir}"
    fi
}

# ── Mocking ────────────────────────────────────────────

# ── Safe script invocation ────────────────────────────

# Run a script with timeout. Usage: run_or_skip <timeout_secs> <script> [args...]
# If the script doesn't exist, the test is skipped.
# If the script hangs past timeout, the test is skipped.
# Returns the output and sets rc to 0/1.
run_or_skip() {
    local timeout_secs="$1"
    shift
    local script_path="$1"
    shift

    if [[ ! -f "$script_path" ]]; then
        test_skip "Script not found: $(basename "$script_path")"
        return 1
    fi

    if ! command -v timeout &>/dev/null; then
        local output rc=0
        output=$("$script_path" "$@" 2>&1) || rc=$?
        printf '%s' "$output"
        return $rc
    fi

    local output rc=0
    output=$(timeout "$timeout_secs" "$script_path" "$@" 2>&1) || rc=$?
    printf '%s' "$output"
    return $rc
}

# Check if a script has a --help flag defined
has_help_flag() {
    local script="$1"
    [[ -f "$script" ]] && grep -q '\-\-help\b' "$script" 2>/dev/null
}

# Run a script with --help if supported, else skip the test
run_help_or_skip() {
    local script="$1"
    if ! has_help_flag "$script"; then
        test_skip "$(basename "$script"): no --help flag"
        return 1
    fi
    run_or_skip 5 "$script" --help
}

# Creates a temporary mock command. Usage:
#   mock_command systemctl 'echo "mocked systemctl $*"; return 0'
#   mock_command nginx 'return 1'  # simulate failure
mock_command() {
    local cmd="$1" body="$2"
    eval "
    $cmd() {
        $body
    }
    export -f $cmd 2>/dev/null || true
    "
}

# Creates a sandbox directory and returns its path
make_sandbox() {
    local prefix="${1:-test-sandbox}"
    mktemp -d "/tmp/${prefix}.XXXXXX"
}

# ── Remote helpers (EC2) ──────────────────────────────

ssh_cmd() {
    local host="${EC2_HOST:?EC2_HOST not set}"
    local user="${EC2_USER:-ubuntu}"
    local key="${EC2_KEY_PATH:-$HOME/.ssh/id_rsa}"
    ssh -i "$key" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$user@$host" "$@"
}

scp_put() {
    local src="$1" dst="$2"
    local host="${EC2_HOST:?EC2_HOST not set}"
    local user="${EC2_USER:-ubuntu}"
    local key="${EC2_KEY_PATH:-$HOME/.ssh/id_rsa}"
    if command -v rsync &>/dev/null; then
        rsync -az --delete -e "ssh -i '$key' -o StrictHostKeyChecking=accept-new" \
            --exclude '.git/' --exclude '.claude/' --exclude '__pycache__/' \
            --exclude '.DS_Store' --exclude '*.pyc' --exclude '.gitignore' \
            "$src" "$user@$host:$dst"
    else
        scp -i "$key" -o StrictHostKeyChecking=accept-new -r "$src" "$user@$host:$dst"
    fi
}

check_ssh_connectivity() {
    ssh_cmd "echo OK" 2>&1
}
