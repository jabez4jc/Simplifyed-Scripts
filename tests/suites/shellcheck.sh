#!/usr/bin/env bash
# ShellCheck static analysis suite
# Usage: source this file (it sources test-utils internally)

suite_shellcheck() {
    local repo_root="${1:-$REPO_ROOT}"
    [[ -d "$repo_root" ]] || { echo "FATAL: REPO_ROOT not found: $repo_root"; return 1; }

    suite_start "ShellCheck Static Analysis"

    if ! command -v shellcheck &>/dev/null; then
        test_skip "shellcheck not installed — install with: brew install shellcheck (macOS) or apt install shellcheck"
        suite_report
        return 0
    fi

    local scripts_sh=()
    local f
    while IFS= read -r -d '' f; do scripts_sh+=("$f"); done < <(find "$repo_root" -maxdepth 1 -name '*.sh' -print0 2>/dev/null)

    if [[ ${#scripts_sh[@]} -eq 0 ]]; then
        test_skip "No .sh files found in $repo_root"
        suite_report
        return 0
    fi

    for f in "${scripts_sh[@]}"; do
        test_start
        bn="$(basename "$f")"
        local output
        output=$(shellcheck -x -S warning "$f" 2>&1)
        local rc=$?
        if [[ $rc -eq 0 ]]; then
            test_pass "shellcheck: $bn"
        else
            local summary
            summary=$(echo "$output" | tail -5 | tr '\n' '; ')
            test_fail "shellcheck: $bn — $summary"
        fi
    done

    suite_report
    return $?
}
