# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a comprehensive collection of bash scripts for managing OpenAlgo trading platform instances on Ubuntu/Debian servers. The scripts automate multi-instance deployment, configuration, monitoring, backup, and updates.

## Architecture

**Core Components:**

1. **quick-setup.sh** - Single instance setup script
   - Automated complete setup in one command
   - Configures 4GB swap automatically
   - Includes all system packages, dependencies, SSL, Nginx, systemd service
   - Interactive prompts for domain, broker, and credentials
   - Best for single instance deployments and quick testing

2. **multi-install.sh** - Main orchestration script
   - Validates system prerequisites (Python 3, pip, uv)
   - Manages system-wide dependencies (nginx, certbot, firewall)
   - Creates isolated instance directories at `/var/python/openalgo-flask/openalgo<N>/`
   - Generates unique configurations per instance (ports, domains, databases)
   - Creates systemd services and Nginx reverse proxy configs
   - Handles SSL certificate generation via Let's Encrypt
   - `/monitor` is a plain reverse proxy to the admin API - login is handled by openalgo-restart-api.py itself, not nginx

3. **update_swap_2gb.sh** - Fixed swap utility
   - Creates or replaces fixed 4GB swap space to prevent OOM during broker authentication

4. **oa-configure-swap.sh** - Flexible swap utility
   - Interactive or command-line driven swap configuration (1-512 GB)
   - Validates disk space before allocation
   - Displays current swap configuration and filesystem usage
   - Includes confirmation prompts and safe reconfiguration

5. **oa-restart.sh** - Instance management (manual)
   - Discovers running instances via systemd
   - Provides interactive menu for restarting single or all instances
   - Auto-reloads Nginx after restart

5a. **setup-daily-restart.sh** - Automated restart scheduler
   - Sets up cron job for daily automatic restart at 8 AM IST
   - Creates restart script at `/usr/local/bin/openalgo-daily-restart.sh`
   - Creates log file at `/var/log/openalgo-daily-restart.log`
   - Verifies/sets system timezone to Asia/Kolkata
   - Provides easy modification commands for restart time

6. **oa-uninstaller.sh** - Cleanup utility
   - Removes instances with full cleanup (service, directories, SSL certs, nginx config)
   - Includes confirmation prompts to prevent accidental deletion

7. **oa-health-check.sh** - Monitoring utility
   - Multi-category health checks (service, ports, configuration, databases, filesystem, logs, connectivity)
   - System-wide health assessment (Nginx, firewall, swap, load)
   - Exit codes for automation (0=healthy, 1=warning, 2=critical)
   - Supports single instance, all instances, or system-only checks

8. **oa-backup.sh** - Backup & restore utility
   - Quick backups (env + databases + configs) with optional GPG encryption
   - Full backups (complete instance archive)
   - Selective restore with current data preservation
   - Automatic cleanup of old backups (configurable retention)
   - Supports single instance, all instances, or specific backup operations

9. **oa-update.sh** - Smart update utility
   - Version-aware .env merging using `ENV_CONFIG_VERSION` field
   - Selective updates (only merge .env when version changes)
   - Pre-update automatic backup
   - Dependency updates via `uv sync`
   - Dry-run mode to preview updates
   - Rollback capability to pre-update backup

10. **make-executable.sh** - Setup utility
   - Finds all `.sh` files in repository automatically
   - Makes them executable with single command
   - Reports success/failure for each script
   - Provides summary and lists all available scripts
   - Simplifies initial setup process

11. **oa-patch-known-issues.sh** - Upstream bug mitigation applier
   - Idempotent, pattern-matched patches for known OpenAlgo bugs that break under this deployment's gunicorn/eventlet setup
   - Called automatically by both installers (before first start) and by `oa-update.sh` (after `git pull` reverts them)
   - `--self-test` verifies patch logic against synthetic samples without touching any instance
   - See "Known Upstream Issue" section below

12. **oa-apply-branding.sh** - Simplifyed rebranding overlay
   - Patches the **pre-built** `frontend/dist` in place; never runs `npm`
   - Applied by both installers (branding is opt-out, default on) and re-applied by `oa-update.sh` after every pull
   - `--self-test` verifies the rewrite rules against a synthetic dist, touching no instance
   - See "Branding" section below

13. **oa-secure-admin.sh** - Admin auth retrofit utility
   - Sets/resets the admin login via `openalgo-restart-api.py --set-admin-password` (app-owned credential store, not nginx)
   - Removes any leftover `auth_basic` directives from an earlier version of this script, so the app's own login page is the only gate
   - Optionally puts the all-instances manager page behind its own domain + TLS instead of raw `IP:8888`
   - Sets `MANAGER_DOMAIN` for openalgo-restart-api.py via a systemd drop-in so in-app links use the new domain
   - Optionally closes public access to port 8888 and binds the API to localhost once nginx is confirmed working
   - Safe to re-run: detects an already-configured domain and leaves it alone unless you choose to reconfigure

## Key Implementation Patterns

**Instance Isolation:**
- Each instance uses a unique port range (Flask: 5000+N, WebSocket: 8765+N, ZMQ: 5555+N)
- Separate SQLite databases per instance (openalgo{N}.db, latency{N}.db, logs{N}.db)
- Unique session/CSRF cookie names (session{N}, csrf_token{N}) to prevent cross-instance pollution
- Individual systemd services with separate Unix sockets. **Service names are derived from the domain, not the index**: `openalgo-<domain with dots as dashes>` (e.g. `fyers.simplifyed.in` → `openalgo-fyers-simplifyed-in`). See multi-install.sh:334-335. `openalgo{N}` is the *directory* name under /var/python/openalgo-flask/ — `systemctl status openalgo2` will always report "unit could not be found".

**Broker Integration:**
- Validates broker names against hardcoded list (30 supported brokers)
- Special handling for XTS-based brokers that require market data API credentials
- Broker credentials injected via `.env` file during installation

**Configuration Management:**
- Uses `.env` file from cloned OpenAlgo repository as template
- Sed-based replacements to update environment variables
- Order of replacements matters (domain → ports → credentials → keys)

**Error Handling:**
- `check_status()` function aborts on any command failure
- Logging via `log_message()` function with color codes
- All logs saved to `logs/install_multi_TIMESTAMP.log`

## Key Features

**Version-Aware .env Updates (oa-update.sh):**
- Reads `ENV_CONFIG_VERSION = 'X.Y.Z'` from both old and new `.sample.env`
- If versions match: skips merge (code-only updates)
- If versions differ: intelligently merges configuration
- Preserves instance-specific settings: ports, broker, credentials, keys, cookies
- Includes custom variables not in template
- Falls back to MD5 hash comparison if version field missing

**Health Check Exit Codes (oa-health-check.sh):**
- 0: All checks passed (healthy)
- 1: One or more warnings detected
- 2: Critical issues found
- Enables automation and monitoring integration

**Backup Encryption (oa-backup.sh):**
- Uses GPG with AES256 cipher for .env files
- Falls back to plain text if GPG unavailable
- Preserves file permissions and ownership
- Creates pre-restore backup of current data

## Common Tasks

**Add support for a new broker:**
1. Add broker name to `valid_brokers` variable in multi-install.sh
2. If XTS-based, add to `xts_brokers` variable
3. Test broker credential validation

**Debug installation failures:**
1. Check latest log: `tail -f logs/install_multi_*.log`
2. Verify systemd service: `sudo systemctl status openalgo-<domain-with-dashes>`
   (find it with `systemctl list-units 'openalgo-*'` — NOT `openalgo<N>`, that's the directory name)
3. Check Nginx config: `sudo nginx -t`
4. View Flask app logs: `sudo journalctl -u openalgo-<domain-with-dashes> -n 50`

**Monitor instance health:**
1. Run health check: `sudo ./oa-health-check.sh all`
2. Check specific instance: `sudo ./oa-health-check.sh openalgo1`
3. Integrate with monitoring: Use exit codes for alerting

**Backup before major changes:**
1. Quick backup: `sudo ./oa-backup.sh all quick`
2. Full backup: `sudo ./oa-backup.sh all full`
3. List backups: `sudo ./oa-backup.sh list`

**Update instances safely:**
1. Dry-run first: `sudo ./oa-update.sh dry-run`
2. Update single: `sudo ./oa-update.sh openalgo1`
3. Update all: `sudo ./oa-update.sh update-all`
4. Rollback if needed: `sudo ./oa-update.sh rollback /path/to/backup openalgo1`

**Modify port allocation strategy:**
Update the port calculation formulas in the instance loop (lines 272-274 in multi-install.sh)

## Known Upstream Issue: WhatsApp auto-start wedges the eventlet worker

**Symptom:** instance returns nginx 504 while `systemctl is-active` says `active` and the process is running. `oa-health-check.sh` reports "Socket accepts but does not respond - worker wedged".

**Cause:** `app.py` auto-starts the WhatsApp bot on a raw `threading.Thread`. That thread acquires an eventlet semaphore, and the hub (on another OS thread) then hits `greenlet.error: Cannot switch to a different thread` inside `fire_timers`, killing its timer/accept loop. Deterministic, ~6s after every boot, on any instance with a paired WhatsApp session. Confirmed 2026-07-27 on openalgo2 (fyers.simplifyed.in).

**Mitigation (automated):** `oa-patch-known-issues.sh` forces the `is_paired` gate in `app.py` false so the bot never auto-starts. The bot still starts manually from the UI; pairing and session blob are untouched. The patch is pattern-matched (not line-numbered), idempotent, self-skipping once upstream fixes the bug, and auto-reverted if the result doesn't compile.

It is applied automatically by `multi-install.sh` and `quick-setup.sh` (before first start) and by `oa-update.sh` (after `git pull`, which reverts it). `oa-update.sh` then gates success on `oa-health-check.sh`'s exit code rather than on `systemctl is-active`, which cannot detect a wedged worker.

**The real fix belongs upstream:** use `eventlet.spawn(_autostart_whatsapp_bot)` instead of `threading.Thread(...)` in `app.py`, or drop the eventlet worker class — gunicorn already warns eventlet is deprecated. Once upstream lands it, the patcher detects the change and skips automatically.

**Adding a future mitigation:** add a `patch_*` function to `oa-patch-known-issues.sh` following the rules in its header, and extend `--self-test` to cover it. Run `./oa-patch-known-issues.sh --self-test` to verify patch logic without touching any instance.

## Branding (oa-apply-branding.sh)

**Why it patches `dist`, not `src`:** OpenAlgo serves a pre-built React app. `blueprints/react_app.py` sets `FRONTEND_DIST = frontend/dist` and serves every route (`/`, `/assets/*`, `/images/*`, `/favicon.ico`, `/logo.png`, `/apple-touch-icon.png`) out of it, and `frontend/dist` is committed upstream. Editing `frontend/src` would require Node 24 + `npm ci` + `vite build` on every server on every update — hundreds of MB per instance and a real OOM risk on 2 GB boxes. So the overlay rewrites the built chunks directly. Nginx proxies everything to gunicorn, so nothing bypasses Flask and no static path escapes the overlay.

**What it changes:** display copy (`OpenAlgo` → `Simplifyed`), outbound links (openalgo.in / GitHub / X / YouTube → `$BRAND_URL`, paths preserved), bare hostnames rendered as visible text (the footer's `www.openalgo.in` label, a chart annotation — these are not URLs, so the link map misses them), the logo/favicon/apple-touch/chart-watermark image files, the Home page header lockup, the `<title>`/description in `dist/index.html`, and the terminal banner strings in `app.py`.

**What it deliberately does NOT change:** `docs.openalgo.in` links, the lowercase `openalgo` SDK package name, `OPENALGO_*` env vars, service names, DB paths, API fields, browser storage keys. Only capitalised `OpenAlgo` is treated as display copy — verified against upstream `main`, where all 137 occurrences in `frontend/src` are copy or comments, none are values.

**Compressed siblings:** `serve_assets()` prefers `<asset>.br` / `.gz` when the client advertises the encoding. A stale sibling would ship pre-branding bytes, so every rewritten chunk gets its `.gz` regenerated and its `.br` rebuilt (`brotli` CLI, installed by both installers) or removed — Flask then falls back to `.gz`, then raw.

**Marker file:** branded instances carry an untracked `.simplifyed-branding` file, which survives `git reset --hard`. `oa-update.sh` re-brands only marked instances, and `oa-apply-branding.sh` with no arguments brands every marked instance.

**Retrofitting existing instances:** `sudo ./oa-apply-branding.sh all` (or a single instance path) brands and marks them. No service restart is needed — Flask reads `frontend/dist` per request. Browsers that visited the instance *before* branding may hold cached chunks (`immutable, max-age=1yr` on content-hashed names that our rewrite does not change); a hard refresh clears it, and the next upstream frontend update resolves it permanently.

**Turning it off:** interactive installers prompt (default yes); `multi-install.sh --config` accepts `BRANDING=n`. Config files predating this variable get the default, so existing Fleet Manager provisioning keeps working unchanged.

**Value guard:** before writing anything, the script scans the built chunks for `OpenAlgo` used as a *value* rather than copy — compared as a constant, an object/JSON key, a `case` label, a storage key, or inside a URL/path. Any hit aborts the whole overlay with the offending snippets printed, leaving the instance on upstream branding (cosmetic problem) instead of half-rewritten (behavioural problem). One reviewed exception is allowlisted: `usePageTitle`'s `document.title = t === 'OpenAlgo' ? ...`, where both operands are literals in the same chunk and rewrite together. If upstream changes that line, the allowlist entry stops matching and the guard re-arms. When the guard fires, narrow the rewrite rules — don't widen the allowlist without checking both operands.

**Degradation, not breakage:** every rewrite is pattern-matched and idempotent. If upstream changes a pattern (e.g. the Home header markup), that piece is simply not rebranded — the page never breaks. The Home lockup falls back to the square Simplifyed mark.

**AGPL:** rebranding does not remove OpenAlgo's licence, copyright, source-availability or appropriate-legal-notice obligations.

## Testing & Validation

### Test Framework

A comprehensive test suite lives in `tests/`. The master runner is:

```bash
bash tests/oa-test.sh --local    # syntax + shellcheck + unit tests
bash tests/oa-test.sh --remote   # integration tests on EC2 (set EC2_HOST)
bash tests/oa-test.sh --all      # local then remote
bash tests/oa-test.sh --suite <name>  # run specific suite
```

| Suite | What it checks |
|-------|----------------|
| `syntax` | `bash -n` on all `.sh`, `python -m py_compile` on `.py` |
| `shellcheck` | ShellCheck at warning level (requires shellcheck) |
| `unit` | Logic tests: patch self-test, broker validation, health exit codes, env version parsing |
| `integration` | SSH connectivity, repo push, tool availability, remote checks |

### EC2 Remote Testing Workflow

For full validation on a live server, set up EC2 access and run:

```bash
export EC2_HOST="ec2-xxx.compute.amazonaws.com"
export EC2_USER="ubuntu"
export EC2_KEY_PATH="$HOME/.ssh/your-key.pem"

bash tests/oa-test.sh --all
```

The integration suite (`tests/suites/integration.sh`) automatically:
1. Tests SSH connectivity
2. SCPs the repo to EC2
3. Runs syntax checks on the remote server
4. Runs `oa-patch-known-issues.sh --self-test` on EC2
5. Verifies all required tools are installed

### Automated Fix Loop (for AI agents)

See `AGENTS.md` for the complete fix loop workflow. In brief:

1. Run `bash tests/oa-test.sh --suite <name>` to identify failures
2. Fix the *source script* (never the test)
3. Re-run the test to verify
4. Push to EC2 and re-run remotely
5. Repeat until all suites pass

### Per-Script Testing Notes

- Scripts require root access; local testing limited to syntax/shellcheck
- `.env` template comes from OpenAlgo repository; verify template variables before sed replacements
- Domain validation uses regex; test with various formats (subdomains, international domains)
- Nginx config uses variables in heredoc; ensure proper escaping of `$` characters
- `ENV_CONFIG_VERSION` field must exist in both old and new `.sample.env` for version comparison
- Health check tests systemd, ports, and files; requires running OpenAlgo instances for full validation
- Backup encryption requires GPG; falls back to plain text gracefully if unavailable
- Update script tests git commands; requires valid git repository with origin remote

## External Dependencies

- **OpenAlgo repository**: Cloned from https://github.com/marketcalls/openalgo.git
- **Python packages**: uv (installed via snap), gunicorn, eventlet, synced via `uv sync`
- **System tools**: nginx, certbot, systemd, timedatectl, sed, awk, grep, curl, ss, df, du
- **Optional tools**: gpg (for backup encryption), git (for updates)

## Implementation Notes

**Error Handling:**
- All scripts use explicit `check_status()` or error checking to fail fast
- Backups are always created before destructive operations
- Service state is preserved and restored on failures
- Colored output distinguishes status (green=success, yellow=warning, red=error)

**Configuration Management:**
- `.env` files contain sensitive credentials (API keys) - encrypted backups recommended
- Instance ports calculated as BASE + instance_number (allows easy scaling)
- Session/CSRF cookie names made unique per instance to prevent cross-instance pollution
- Timezone validated as IST (Asia/Kolkata) for Indian stock market compatibility

**Security:**
- WebSocket/ZMQ ports bound to localhost; external access only through Nginx SSL
- Firewall configured to allow SSH, HTTP, HTTPS only
- File permissions restrict instance directories to www-data user
- Keys directory (700 permissions) holds sensitive authentication data
- All scripts require sudo; no security bypass mechanisms
- The admin dashboard (`openalgo-restart-api.py`, port 8888 - Factory Reset, Reboot Server, per-instance restart/stop/start, SQL terminal) requires login: a styled page + PBKDF2-hashed credentials in `/etc/openalgo/admin-auth.json` + an in-memory session cookie, gating both `/` (manager) and `/monitor` (per-instance). Set/change credentials with `sudo python3 openalgo-restart-api.py --set-admin-password` (also offered by `api-manager.sh` on first install and via its menu, and by `oa-secure-admin.sh`). This intentionally replaces nginx `auth_basic` so the login prompt is stylable rather than the browser's native dialog - don't reintroduce `auth_basic` alongside it, that stacks two logins.

**Version Management:**
- OpenAlgo devs increment `ENV_CONFIG_VERSION` ONLY when `.env` structure changes
- This enables smart updates: code-only changes skip .env processing
- Version mismatch detection prevents configuration drift across instances
