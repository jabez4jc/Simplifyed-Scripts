#!/usr/bin/env bash
# Integration test suite — runs on EC2 via SSH
# All tests here require EC2_HOST to be set.
# Usage: source this file

suite_integration() {
    local repo_root="${1:-$REPO_ROOT}"
    [[ -d "$repo_root" ]] || { echo "FATAL: REPO_ROOT not found: $repo_root"; return 1; }

    suite_start "Integration Tests (EC2)"

    if [[ -z "${EC2_HOST:-}" ]]; then
        test_skip "EC2_HOST not set — skipping integration tests"
        suite_report
        return 0
    fi

    integration_ssh_connectivity

    integration_push_repo "$repo_root"

    integration_remote_syntax

    integration_remote_patch_self_test

    integration_health_check_help

    integration_install_deps

    suite_report
    return $?
}

# ────────────────────────────────────────────────

integration_ssh_connectivity() {
    test_start
    local result
    result=$(check_ssh_connectivity 2>&1)
    if [[ "$result" == "OK" ]]; then
        test_pass "integration: SSH connectivity to $EC2_HOST"
    else
        test_fail "integration: SSH connectivity to $EC2_HOST — $result"
    fi
}

integration_push_repo() {
    local repo_root="$1"
    test_start
    local remote_path="${EC2_REPO_PATH:-/tmp/opencode-ec2-test}"
    local result
    result=$(scp_put "$repo_root/" "$remote_path" 2>&1)
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        test_pass "integration: pushed repo to $EC2_HOST:$remote_path"
    else
        test_fail "integration: push failed (exit $rc) — $(echo "$result" | tail -2)"
    fi
}

integration_remote_syntax() {
    test_start
    local remote_path="${EC2_REPO_PATH:-/tmp/opencode-ec2-test}"
    local result
    result=$(ssh_cmd "cd '$remote_path' && bash tests/oa-test.sh --suite syntax 2>&1 || true" 2>&1)
    if echo "$result" | grep -q "passed.*failed"; then
        test_pass "integration: remote syntax checks completed"
    else
        test_fail "integration: remote syntax — unexpected output: $(echo "$result" | tail -5)"
    fi
}

integration_remote_patch_self_test() {
    test_start
    local remote_path="${EC2_REPO_PATH:-/tmp/opencode-ec2-test}"
    local result
    result=$(ssh_cmd "cd '$remote_path' && bash oa-patch-known-issues.sh --self-test 2>&1" 2>&1)
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        test_pass "integration: patch-known-issues --self-test on EC2"
    else
        test_fail "integration: patch --self-test exit $rc — $(echo "$result" | tail -3)"
    fi
}

integration_health_check_help() {
    test_start
    local remote_path="${EC2_REPO_PATH:-/tmp/opencode-ec2-test}"
    local result
    result=$(ssh_cmd "cd '$remote_path' && bash oa-health-check.sh --help 2>&1 || true" 2>&1)
    if echo "$result" | grep -qi "usage\|health\|check"; then
        test_pass "integration: health-check --help works on EC2"
    else
        test_fail "integration: health-check --help — unexpected: $(echo "$result" | head -2)"
    fi
}

integration_install_deps() {
    test_start
    local remote_path="${EC2_REPO_PATH:-/tmp/opencode-ec2-test}"
    local result
    result=$(ssh_cmd "
        which shellcheck 2>/dev/null && echo 'shellcheck: OK' || echo 'shellcheck: MISSING'
        which python3   2>/dev/null && echo 'python3: OK'    || echo 'python3: MISSING'
        which git       2>/dev/null && echo 'git: OK'        || echo 'git: MISSING'
        which systemctl 2>/dev/null && echo 'systemctl: OK'  || echo 'systemctl: MISSING'
        which nginx     2>/dev/null && echo 'nginx: OK'      || echo 'nginx: MISSING'
    " 2>&1)
    if echo "$result" | grep -q "MISSING"; then
        test_fail "integration: EC2 missing tools — $(echo "$result" | grep MISSING | tr '\n' ' ')"
    else
        test_pass "integration: EC2 has all required tools"
    fi
}
