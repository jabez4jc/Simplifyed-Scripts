#!/usr/bin/env bash
# Syntax check suite — bash -n for .sh, python -m py_compile for .py
# Usage: source this file (it sources test-utils internally)

suite_syntax() {
    local repo_root="${1:-$REPO_ROOT}"
    [[ -d "$repo_root" ]] || { echo "FATAL: REPO_ROOT not found: $repo_root"; return 1; }

    suite_start "Syntax Checks (bash -n + python -m py_compile)"

    local scripts_sh=()
    local scripts_py=()
    local f

    while IFS= read -r -d '' f; do scripts_sh+=("$f"); done < <(find "$repo_root" -maxdepth 1 -name '*.sh' -print0 2>/dev/null)
    while IFS= read -r -d '' f; do scripts_py+=("$f"); done < <(find "$repo_root" -maxdepth 1 -name '*.py' -print0 2>/dev/null)

    if [[ ${#scripts_sh[@]} -eq 0 && ${#scripts_py[@]} -eq 0 ]]; then
        test_skip "No scripts found in $repo_root"
        suite_report
        return 0
    fi

    for f in "${scripts_sh[@]}"; do
        test_start
        bn="$(basename "$f")"
        if bash -n "$f" 2>/dev/null; then
            test_pass "bash -n: $bn"
        else
            local err
            err=$(bash -n "$f" 2>&1)
            test_fail "bash -n: $bn — $err"
        fi
    done

    for f in "${scripts_py[@]}"; do
        test_start
        bn="$(basename "$f")"
        if python3 -B -c "import ast; ast.parse(open('$f').read())" 2>/dev/null; then
            test_pass "python ast.parse: $bn"
        else
            local err
            err=$(python3 -B -c "import ast; ast.parse(open('$f').read())" 2>&1)
            test_fail "python ast.parse: $bn — $err"
        fi
    done

    suite_report
    return $?
}
