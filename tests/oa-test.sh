#!/usr/bin/env bash
# Master test runner for Simplifyed Scripts
#
# Usage:
#   tests/oa-test.sh --local        # Run all local tests (syntax + shellcheck + unit)
#   tests/oa-test.sh --remote       # SSH to EC2 and run integration tests
#   tests/oa-test.sh --all          # Local + remote (if EC2_HOST set)
#   tests/oa-test.sh --suite syntax # Run only the syntax suite
#   tests/oa-test.sh --help         # Show this help
#
# Environment variables:
#   EC2_HOST       - EC2 hostname/IP (required for --remote)
#   EC2_USER       - SSH user (default: ubuntu)
#   EC2_KEY_PATH   - Path to SSH key (default: ~/.ssh/id_rsa)
#   EC2_REPO_PATH  - Remote path for repo copy (default: /tmp/opencode-ec2-test)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export REPO_ROOT

# Source test utilities
source "$REPO_ROOT/tests/lib/test-utils.sh"

# Source all suites
source "$REPO_ROOT/tests/suites/syntax.sh"
source "$REPO_ROOT/tests/suites/shellcheck.sh"
source "$REPO_ROOT/tests/suites/unit.sh"
source "$REPO_ROOT/tests/suites/integration.sh"

# ── CLI ───────────────────────────────────────────────

show_help() {
    cat <<EOF
Simplifyed Scripts — Test Runner

Usage:  tests/oa-test.sh [OPTIONS]

Options:
  --local              Run all local tests (syntax + shellcheck + unit)
  --remote             Run integration tests on EC2 (requires EC2_HOST)
  --all                Run local then remote (if EC2_HOST set)
  --suite <name>       Run a specific suite: syntax | shellcheck | unit | integration
  --list               List available test suites
  --help               Show this help

Examples:
  tests/oa-test.sh --local
  EC2_HOST=ec2-xxx.compute.amazonaws.com tests/oa-test.sh --remote
  tests/oa-test.sh --suite syntax
  tests/oa-test.sh --all
EOF
}

list_suites() {
    echo "Available test suites:"
    echo "  syntax       — bash -n + python -m py_compile checks"
    echo "  shellcheck   — ShellCheck static analysis (requires shellcheck)"
    echo "  unit         — Unit tests for critical scripts"
    echo "  integration  — EC2 integration tests (requires EC2_HOST)"
}

OVERALL_PASSED=0
OVERALL_FAILED=0
OVERALL_SKIPPED=0

run_suite() {
    local name="$1"
    shift
    local rc=0
    case "$name" in
        syntax)      suite_syntax "$@" || rc=$? ;;
        shellcheck)  suite_shellcheck "$@" || rc=$? ;;
        unit)        suite_unit "$@" || rc=$? ;;
        integration) suite_integration "$@" || rc=$? ;;
        *)           echo "ERROR: unknown suite '$name'. Use --list to see available suites." >&2; return 1 ;;
    esac
    OVERALL_PASSED=$((OVERALL_PASSED + TESTS_PASSED))
    OVERALL_FAILED=$((OVERALL_FAILED + TESTS_FAILED))
    OVERALL_SKIPPED=$((OVERALL_SKIPPED + TESTS_SKIPPED))
    return $rc
}

# ── Main ──────────────────────────────────────────────

MODE=""
SUITE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)    show_help; exit 0 ;;
        --list)    list_suites; exit 0 ;;
        --local)   MODE="local"; shift ;;
        --remote)  MODE="remote"; shift ;;
        --all)     MODE="all"; shift ;;
        --suite)   SUITE="$2"; shift 2 ;;
        *)         echo "ERROR: unknown option '$1'. Use --help." >&2; exit 1 ;;
    esac
done

if [[ -n "$SUITE" ]]; then
    run_suite "$SUITE"
    exit $?
fi

case "$MODE" in
    local)
        run_suite syntax
        run_suite shellcheck
        run_suite unit
        ;;
    remote)
        run_suite integration
        ;;
    all)
        run_suite syntax
        run_suite shellcheck
        run_suite unit
        if [[ -n "${EC2_HOST:-}" ]]; then
            run_suite integration
        else
            echo ""
            printf "${YELLOW}EC2_HOST not set — skipping integration tests${NC}\n"
        fi
        ;;
    "")
        echo "ERROR: specify --local, --remote, --all, or --suite. Use --help for details." >&2
        exit 1
        ;;
esac

# Final summary
echo ""
printf "${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
printf "${BOLD}  FINAL: %d passed, %d failed, %d skipped${NC}\n" "$OVERALL_PASSED" "$OVERALL_FAILED" "$OVERALL_SKIPPED"
printf "${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"

if [[ $OVERALL_FAILED -gt 0 ]]; then
    echo ""
    printf "${RED}Failed suites:${NC}\n"
    # We can't easily enumerate which suites failed without per-suite tracking.
    # The suite_report output above will show failures inline.
fi

exit $(( OVERALL_FAILED > 0 ? 1 : 0 ))
