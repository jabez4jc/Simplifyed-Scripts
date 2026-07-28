# Agent Guide: EC2 Remote Testing & Automated Fix Loop

This file instructs AI coding agents (Claude Code, Codex, etc.) on how to
connect to an AWS EC2 instance, run the full test suite against the live
scripts, detect and fix failures, and validate the fixes.

## Quick Start

```bash
# 1. Set your EC2 connection
export EC2_HOST="ec2-13-127-20-39.ap-south-1.compute.amazonaws.com"
export EC2_USER="ubuntu"
export EC2_KEY_PATH="$HOME/.ssh/openalgoec2.pem"

# 2. Run local tests first
bash tests/oa-test.sh --local

# 3. Run integration tests on EC2
bash tests/oa-test.sh --remote

# 4. Run everything
bash tests/oa-test.sh --all
```

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `EC2_HOST` | For remote | — | EC2 hostname or IP address |
| `EC2_USER` | No | `ubuntu` | SSH username |
| `EC2_KEY_PATH` | No | `~/.ssh/id_rsa` | Path to SSH private key |
| `EC2_REPO_PATH` | No | `/tmp/opencode-ec2-test` | Remote directory for repo copy |

## Test Suites

| Suite | Command | Description | Local? | Remote? |
|-------|---------|-------------|--------|---------|
| syntax | `--suite syntax` | `bash -n` + `python -m py_compile` on all scripts | ✓ | ✓ |
| shellcheck | `--suite shellcheck` | ShellCheck static analysis at warning level | ✓ | ✓ |
| unit | `--suite unit` | Logic tests for critical scripts (patch, brokers, exit codes, env versions, backup) | ✓ | ✓ |
| integration | `--suite integration` | SSH connectivity, repo push, remote checks, tool availability | ✗ | ✓ |

## Automated Fix Loop

When fixing scripts, follow this iterative process:

### Loop Steps

```
1. Run tests:       bash tests/oa-test.sh --suite <suite>
2. Read failures:   Identify which tests failed and why
3. Fix source:      Edit the failing script in the repo root
4. Re-run tests:    Verify the fix passes
5. Push to EC2:     Only after local tests pass, run --remote
6. Re-run remote:   Verify on actual server
7. Repeat:          Until all suites pass
```

### Fix Principles

- **Never inline-patch tests** — if a test fails, fix the *source* script, not the test
- **One fix per run** — make focused changes and re-validate before moving on
- **Preserve conventions** — match existing code style in the repo (see CLAUDE.md)
- **Check side effects** — after fixing, ensure other tests still pass (regression check)
- **Document decisions** — if a test reveals a design issue, note it in the fix

### Common Failure Patterns & Fixes

| Failure | Likely Cause | Fix Approach |
|---------|--------------|--------------|
| `bash -n` syntax error | Missing quote, unclosed brace, bad escape | Fix the syntax error in the source |
| `shellcheck` warning | Unquoted variable, unused arg, POSIX violation | Quote the variable, remove unused code |
| `--self-test` failure | Patch pattern doesn't match upstream code | Update the regex in oa-patch-known-issues.sh |
| Missing `--help` flag | Script lacks usage documentation | Add `--help` handling per existing pattern |
| Integration SSH failure | Wrong EC2_HOST, key permissions, security group | Verify EC2_HOST, fix key perms (chmod 400), check SG |
| Integration tool missing | EC2 lacks required package | SSH and install the dependency (shellcheck, python3, etc.) |

## Remote Testing Architecture

```
┌─ Your Machine ───────────────────────────────────────┐
│  tests/oa-test.sh --remote                            │
│    1. Check SSH connectivity                          │
│    2. scp/rsync repo → EC2:$EC2_REPO_PATH             │
│    3. ssh → run syntax tests                          │
│    4. ssh → run ShellCheck                            │
│    5. ssh → run unit tests                            │
│    6. ssh → run patch self-test                       │
│    7. ssh → verify required tools                     │
│    8. Report results                                  │
└──────────────────────────────────────────────────────┘
                         │ SSH
                         ▼
┌─ EC2 Instance ────────────────────────────────────────┐
│  /tmp/opencode-ec2-test/                               │
│  ├── multi-install.sh    (tested via bash -n on EC2)   │
│  ├── oa-health-check.sh  (validated on actual system)  │
│  ├── oa-update.sh        (dry-run on actual .env)      │
│  └── ...                                               │
└───────────────────────────────────────────────────────┘
```

## Adding New Tests

When adding a test for a script:

1. If it's a logic/unit test, add a function `unit_<script>_<feature>()` to `tests/suites/unit.sh`
2. If it's a remote-only test, add it to `tests/suites/integration.sh`
3. Follow the existing assertion patterns from `tests/lib/test-utils.sh`
4. Run `bash tests/oa-test.sh --suite unit` to verify the new test works

Test function template:

```bash
unit_my_script_feature() {
    local rr="$1"
    local script="$rr/my-script.sh"
    test_start
    if [[ ! -f "$script" ]]; then
        test_skip "my-script.sh not found"
        return
    fi
    # ... test logic ...
    local output
    output=$("$script" --some-flag 2>&1 || true)
    if echo "$output" | grep -q "expected pattern"; then
        test_pass "my-script: feature works"
    else
        test_fail "my-script: feature broken — $(echo "$output" | head -1)"
    fi
}
```

Then register it in `suite_unit()` in unit.sh by adding a call:

```bash
unit_my_script_feature "$repo_root"
```

## CI/CD — GitHub Actions Auto-Testing

A CI workflow runs automatically on every push/PR to `main`:

```
push/PR ──► Local Tests (syntax + shellcheck + unit)
                                   │
                            [all pass?]
                                   │
                              push to main?
                                   │
                       [EC2 secrets configured?]
                                   │
                              ┌────┘
                              ▼
                    Integration Tests on EC2
```

### Workflow

| Event | What runs | Where |
|-------|-----------|-------|
| Push to PR branch | Local tests | GitHub runner |
| Push to `main` | Local + EC2 integration | GitHub runner + EC2 |
| PR opened/synced | Local tests | GitHub runner |

### Setup: Add GitHub Secrets

For EC2 integration tests to run in CI, add these **repository secrets** (Settings → Secrets and variables → Actions):

| Secret | Value |
|--------|-------|
| `EC2_HOST` | `ec2-13-127-20-39.ap-south-1.compute.amazonaws.com` |
| `EC2_USER` | `ubuntu` |
| `EC2_KEY` | Content of `~/.ssh/openalgoec2.pem` (the full private key) |

The `remote` job is skipped automatically if `EC2_HOST` is not set, so it's safe to merge without secrets.

### Local CI Dry-Run

To test the CI workflow locally before pushing:

```bash
# Using act (https://github.com/nektos/act)
act -j local

# Or just run the tests directly
bash tests/oa-test.sh --all
```

## SSH Security Notes

- The SSH key should have `chmod 400` permissions
- EC2 security group must allow inbound SSH (port 22) from your IP
- The agent never stores credentials — they're passed via environment variables
- All remote commands run non-interactively; no `sudo` is assumed unless the script needs it
- If a script requires root on EC2, the test will note it; you may need to run via `sudo`
