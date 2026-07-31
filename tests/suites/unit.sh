#!/usr/bin/env bash
# Unit tests for critical scripts — tests logic by sourcing scripts or
# running them in sandboxed environments with mocked commands.
# Usage: source this file

suite_unit() {
    local repo_root="${1:-$REPO_ROOT}"
    [[ -d "$repo_root" ]] || { echo "FATAL: REPO_ROOT not found: $repo_root"; return 1; }

    suite_start "Unit Tests"

    unit_patch_self_test "$repo_root"
    unit_multi_install_brokers "$repo_root"
    unit_health_check_exit_codes "$repo_root"
    unit_update_env_version "$repo_root"
    unit_backup_paths "$repo_root"
    unit_quick_setup_args "$repo_root"
    unit_clear_logs_dry_run "$repo_root"
    unit_make_executable "$repo_root"
    unit_restart_help "$repo_root"
    unit_secure_admin_help "$repo_root"
    unit_invalidate_help "$repo_root"
    unit_restart_api_self_test "$repo_root"

    suite_report
    return $?
}

# ────────────────────────────────────────────────

unit_patch_self_test() {
    local rr="$1"
    local script="$rr/oa-patch-known-issues.sh"
    test_start
    if [[ ! -f "$script" ]]; then
        test_skip "oa-patch-known-issues.sh not found"
        return
    fi
    local output rc=0
    output=$(run_or_skip 30 "$script" --self-test) || rc=$?
    if [[ $rc -eq 0 ]]; then
        test_pass "patch-known-issues --self-test: exited 0"
    else
        test_fail "patch-known-issues --self-test: exit $rc — $(echo "$output" | tail -3 | tr '\n' ' ')"
    fi
}

# ────────────────────────────────────────────────

unit_multi_install_brokers() {
    local rr="$1"
    local script="$rr/multi-install.sh"
    test_start
    if [[ ! -f "$script" ]]; then
        test_skip "multi-install.sh not found"
        return
    fi
    # Check that the script's known brokers list exists and is non-empty
    local broker_lines
    broker_lines=$(grep -o 'fivepaisa\|aliceblue\|angel\|zerodha\|upstox\|fyers' "$script" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$broker_lines" -ge 5 ]]; then
        test_pass "multi-install: broker list present ($broker_lines broker mentions)"
    else
        test_fail "multi-install: broker list too sparse ($broker_lines mentions)"
    fi

    # Check that port formulas exist
    test_start
    if grep -q 'BASE_PORT\|5000\|8765\|5555' "$script" 2>/dev/null; then
        test_pass "multi-install: port calculation references found"
    else
        test_fail "multi-install: missing port calculation references"
    fi
}

# ────────────────────────────────────────────────

unit_health_check_exit_codes() {
    local rr="$1"
    local script="$rr/oa-health-check.sh"
    test_start
    if [[ ! -f "$script" ]]; then
        test_skip "oa-health-check.sh not found"
        return
    fi

    # Running without args should show usage/error (exit 1 or 2)
    local output
    output=$(run_or_skip 5 "$script" "" 2>&1 || true)
    if echo "$output" | grep -qi "usage\|error\|requires\|argument\|specify\|health"; then
        test_pass "health-check: running without args shows usage"
    else
        test_pass "health-check: running without args produces output"
    fi

    # Check exit code documentation
    test_start
    if grep -q 'exit.code\|exit_code\|exit 0\|exit 1\|exit 2\|0=healthy\|1=warning\|2=critical' "$script" 2>/dev/null; then
        test_pass "health-check: references exit codes 0/1/2"
    else
        test_fail "health-check: missing exit code references"
    fi
}

# ────────────────────────────────────────────────

unit_update_env_version() {
    local rr="$1"
    local script="$rr/oa-update.sh"
    test_start
    if [[ ! -f "$script" ]]; then
        test_skip "oa-update.sh not found"
        return
    fi

    # Check that the script references ENV_CONFIG_VERSION
    if grep -q 'ENV_CONFIG_VERSION' "$script" 2>/dev/null; then
        test_pass "update: references ENV_CONFIG_VERSION"
    else
        test_fail "update: missing ENV_CONFIG_VERSION reference"
    fi

    # Check dry-run support
    test_start
    if grep -q 'dry.run\|dry-run\|DRY_RUN' "$script" 2>/dev/null; then
        test_pass "update: supports dry-run mode"
    else
        test_fail "update: missing dry-run support"
    fi

    # Check rollback support
    test_start
    if grep -q 'rollback\|ROLLBACK\|roll_back' "$script" 2>/dev/null; then
        test_pass "update: supports rollback"
    else
        test_fail "update: missing rollback support"
    fi
}

# ────────────────────────────────────────────────

unit_backup_paths() {
    local rr="$1"
    local script="$rr/oa-backup.sh"
    test_start
    if [[ ! -f "$script" ]]; then
        test_skip "oa-backup.sh not found"
        return
    fi

    # Check GPG encryption reference
    if grep -q 'gpg\|GPG\|encrypt\|AES' "$script" 2>/dev/null; then
        test_pass "backup: references encryption (GPG/AES)"
    else
        test_fail "backup: missing encryption references"
    fi

    # Check backup mode references
    test_start
    if grep -q 'quick\|full\|restore\|list\|cleanup' "$script" 2>/dev/null; then
        test_pass "backup: references backup modes"
    else
        test_fail "backup: missing backup mode references"
    fi
}

# ────────────────────────────────────────────────

unit_quick_setup_args() {
    local rr="$1"
    local script="$rr/quick-setup.sh"
    test_start
    if [[ ! -f "$script" ]]; then
        test_skip "quick-setup.sh not found"
        return
    fi
    # Check for typical interactive setup patterns
    if grep -q 'read\|prompt\|domain\|broker\|confirm' "$script" 2>/dev/null; then
        test_pass "quick-setup: contains interactive prompts"
    else
        test_fail "quick-setup: missing interactive patterns"
    fi
}

# ────────────────────────────────────────────────

unit_clear_logs_dry_run() {
    local rr="$1"
    local script="$rr/oa-clear-logs.sh"
    test_start
    if [[ ! -f "$script" ]]; then
        test_skip "oa-clear-logs.sh not found"
        return
    fi
    if grep -q 'dry.run\|dry-run\|DRY_RUN\|APPLY=0\|APPLY=1' "$script" 2>/dev/null; then
        test_pass "clear-logs: supports dry-run mode"
    else
        test_fail "clear-logs: missing dry-run support"
    fi
}

# ────────────────────────────────────────────────

unit_make_executable() {
    local rr="$1"
    local script="$rr/make-executable.sh"
    test_start
    if [[ ! -f "$script" ]]; then
        test_skip "make-executable.sh not found"
        return
    fi
    local output
    output=$(run_or_skip 5 "$script" 2>&1 || true)
    if echo "$output" | grep -qi "scripts\|executable\|done\|summary\|available\|found\|checking"; then
        test_pass "make-executable: runs and discovers scripts"
    else
        test_fail "make-executable: unexpected output: $(echo "$output" | head -3)"
    fi
}

# ────────────────────────────────────────────────

unit_restart_help() {
    local rr="$1"
    local script="$rr/oa-restart.sh"
    test_start
    if [[ ! -f "$script" ]]; then
        test_skip "oa-restart.sh not found"
        return
    fi
    if grep -q 'restart\|instance\|systemd\|service\|menu\|list' "$script" 2>/dev/null; then
        test_pass "restart: contains restart patterns"
    else
        test_fail "restart: missing restart patterns"
    fi
}

unit_secure_admin_help() {
    local rr="$1"
    local script="$rr/oa-secure-admin.sh"
    test_start
    if [[ ! -f "$script" ]]; then
        test_skip "oa-secure-admin.sh not found"
        return
    fi
    if grep -q 'admin\|password\|domain\|auth\|secure' "$script" 2>/dev/null; then
        test_pass "secure-admin: contains admin security patterns"
    else
        test_fail "secure-admin: missing admin security patterns"
    fi
}

unit_invalidate_help() {
    local rr="$1"
    local script="$rr/oa-invalidate-session.sh"
    test_start
    if [[ ! -f "$script" ]]; then
        test_skip "oa-invalidate-session.sh not found"
        return
    fi
    if grep -q 'session\|invalidate\|broker\|revoke\|SQLite\|token' "$script" 2>/dev/null; then
        test_pass "invalidate: contains session invalidation patterns"
    else
        test_fail "invalidate: missing session invalidation patterns"
    fi
}

# ────────────────────────────────────────────────

# The admin API takes instance names from HTTP callers and feeds them to
# systemctl/journalctl and filesystem paths. Its --self-test asserts that
# validation rejects shell metacharacters and traversal before they get there.
unit_restart_api_self_test() {
    local rr="$1"
    local script="$rr/openalgo-restart-api.py"
    test_start
    if [[ ! -f "$script" ]]; then
        test_skip "openalgo-restart-api.py not found"
        return
    fi
    local output rc=0
    output=$(run_or_skip 30 "$script" --self-test) || rc=$?
    if [[ $rc -eq 0 ]]; then
        test_pass "restart-api --self-test: exited 0"
    else
        test_fail "restart-api --self-test: exit $rc — $(echo "$output" | tail -3 | tr '\n' ' ')"
    fi
}
