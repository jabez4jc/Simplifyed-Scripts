# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a comprehensive collection of bash scripts for managing OpenAlgo trading platform instances on Ubuntu/Debian servers. The scripts automate multi-instance deployment, configuration, monitoring, backup, and updates.

## Architecture

**Entry points (what operators run):**

- **install.sh** - one-line bootstrap (`curl -fsSL .../install.sh | sudo bash`). Clones/updates this repo at `/root/Simplifyed-Scripts` (the first path `openalgo-restart-api.py` looks in), links `/usr/local/bin/oa`, then runs `oa install` with stdin from `/dev/tty`. On a server that already has instances it only updates the repo and links `oa` - it never installs.
- **oa.sh** (`oa`) - thin dispatcher over the scripts below; no logic of its own beyond defaults. `oa install`/`oa add` = swap if none (4 GB) + `OA_DEFAULTS=1 multi-install.sh` (asks only: instance count, then domain/broker/key/secret per instance) + `api-manager.sh setup` if the dashboard isn't running (non-menu mode: generates the admin password and shows it once, skips the optional manager-domain step). Keep installs to necessary questions only - default everything else. Every `oa` command except help first self-updates the repo (`git pull --ff-only`, then re-execs) and refreshes the dashboard copy in /usr/local/bin, so pushed fixes reach servers without extra steps. `oa update` then runs `oa-update.sh` with `OA_UPDATE_TAG` = newest GitHub release (`--main` for tip of main), then `api-manager.sh setup` so servers without the dashboard/timers get them (idempotent: keeps an existing admin login, and keeps 8888 closed when oa-secure-admin bound the API to 127.0.0.1). The individual scripts stay callable directly - Fleet Manager and the dashboard use them.
- **oa-auto-update.sh** - opt-in per instance via an untracked `.simplifyed-autoupdate` marker (`daily` or `sunday`). systemd timer `oa-auto-update.timer` at 03:30 IST, `Persistent=false` (a missed run must never fire at boot mid-session); `run` also refuses outside 03:00-06:00 IST without `--force`. Installs the newest GitHub **Release** that is >= `SOAK_HOURS` (72) old, never moves an instance backwards (`merge-base --is-ancestor`), updates instances one at a time, auto-rolls back a failure and stops the rollout. Telegram notices (config `/etc/simplifyed/auto-update.conf`, 600; token passed to curl via `-K -`, never argv): once per new release (with install dates) and after each run that did something. `--self-test` covers release selection and scheduling. Crypto instances trade 24/7: anything that restarts instances unattended must stay opt-in.

- **oa-repair.sh** (`oa repair`) - verify-and-fix, run automatically after installs (new instances only), as oa-update.sh's post-restart gate, and after rollbacks. Checks every SQLite (`PRAGMA quick_check`, read-only) and DuckDB (read-only open) file in `db/` or named in `.env`; "locked"/"busy" = in use, never damage; ambiguous errors (e.g. DuckDB version mismatch) are reported and left alone. Damaged DBs: service stopped, file + `-wal/-shm/-journal` moved to `db/damaged-<ts>/` (purged after 7 days - quarantined, not deleted, because openalgo.db holds users/API keys/broker logins), a healthy copy from the latest `/tmp/openalgo_backup_<inst>_*` restored (+ migrations) when there is one, else OpenAlgo recreates it on start. Also fixes db/ ownership, `*_DATABASE_URL` keys that point at the main DB (an old unanchored installer sed did that to HEALTH/SANDBOX/HISTORIFY; reset to `.sample.env` defaults), and a stopped/disabled/non-serving service (one retry). Deletes orphaned `db/*.db|*.duckdb` (not named by any DB key in `.env` nor OpenAlgo's default for a key `.env` omits - e.g. HISTORIFY_DATABASE_PATH → db/historify.duckdb; nothing deleted if `.env` lacks DATABASE_URL or a process has the file open). "Serving" = service active + any HTTP answer on the socket - never the full health check's exit code (its CRITICAL includes a full disk, which a restart can't fix). At >=85% disk it runs oa-clear-logs.sh (--no-docker) and deletes /var/backups/openalgo files >14 days, then lists what is still big; disk is never BROKEN (exit 2 would make oa-update roll back). Exit 0 healthy / 1 repaired / 2 still broken. `--self-test` covers the classifier.

**oa-update.sh contract used by the above:** `OA_UPDATE_TAG=<tag>` targets a release instead of `origin/<default>`; the pre-update backup (`/tmp/openalgo_backup_<inst>_<ts>`) records `COMMIT` and holds top-level `db/` files only (no `damaged-*`/restore folders, no `*.duckdb` - Historify can be GBs; rollback replaces only backed-up files and never deletes the DuckDB); `rollback` restores code (`reset --hard COMMIT`), dependencies, overlays, `.env` and databases, then runs oa-repair.sh; the exit status is non-zero on any failure. Migrations run as **www-data** with the instance venv (`run_migrations`), never as root: root-run migrations left root-owned DB/-wal/-shm files ("attempt to write a readonly database"). Never pre-create DB files (an empty file is not a valid DuckDB database) - OpenAlgo creates them.

**Core Components:**

- **multi-install.sh** - the installer behind `oa install`/`oa add`. Numbers new instances after existing ones (`openalgo<N>`), clones OpenAlgo, venv via `uv`, writes `.env` (keys matched by key name, `OPENALGO_WORKER_CLASS = 'gthread'`, `TRUST_PROXY_HEADERS = 'TRUE'`, `.env` chmod 600), nginx + Let's Encrypt, systemd unit on upstream's launcher, branding, known-issue patches, then `oa-repair.sh` per new instance. `--config FILE` = non-interactive (Fleet Manager). `/monitor` is a plain reverse proxy to the admin API - login is handled by openalgo-restart-api.py itself, not nginx.
- **quick-setup.sh** - older single-instance installer, kept working (same fixes as multi-install) but superseded by `oa install`.
- **oa-update.sh** (`oa update`) - see the contract above. `.env` is always rebuilt from the new `.sample.env` with every old value overlaid except `ENV_CONFIG_VERSION` and the Historify path keys (no version-skip, no MD5); `sync_supported_brokers` then takes `VALID_BROKERS` from `.sample.env`. Dependencies from `requirements-nginx.txt` (or `uv sync`), then `ensure_gunicorn`. `dry-run` previews.
- **oa-health-check.sh** (`oa status`) - read-only; exit 0 healthy / 1 warnings / 2 critical; probes the gunicorn socket end to end (detects a wedged worker that systemd calls active).
- **oa-backup.sh** (`oa backup`) - quick (env, GPG-encrypted when gpg exists; databases; nginx + unit) or full archives to `/var/backups/openalgo` (`OA_BACKUP_DIR` overrides; `$1` is the command, never the folder).
- **oa-restart.sh**, **oa-uninstaller.sh** (`oa remove`: service, files, nginx, certificate), **oa-configure-swap.sh** (`oa swap`, 1-512 GB; asks to confirm - `oa install` pipes `y`), **update_swap_2gb.sh** (fixed 4 GB despite the name).
- **setup-daily-restart.sh** (`oa daily-restart`) - opt-in 8 AM IST cron restart of ALL instances; never default (crypto instances).
- **api-manager.sh** (`oa admin`) - installs the dashboard (`openalgo-restart-api.py` copied to /usr/local/bin - a copy, refreshed by `oa update`/auto-update), its service, firewall rule for 8888, the 03:10 cleanup and 07:00/19:00 health-check timers. `api-manager.sh setup` runs that once without the menu.
- **oa-secure-admin.sh** - manager domain + TLS for the dashboard, `MANAGER_DOMAIN` drop-in, optionally closes 8888 / binds the API to localhost; removes legacy nginx `auth_basic`. Safe to re-run.
- **oa-reset-admin.sh** (dashboard Factory Reset) and **oa-invalidate-session.sh** (dashboard Invalidate) - write to an instance's SQLite DB; reads are `sqlite3 -readonly`, and reset re-chowns `db/` after writing as root.
- **oa-clear-logs.sh** - log/temp cleanup (03:10 timer). Note `/tmp` cleanup and reboots remove the `/tmp/openalgo_backup_*` rollback backups.
- **oa-patch-known-issues.sh** - upstream bug mitigations (see below). **oa-apply-branding.sh** - branding overlay (see below).
- **make-executable.sh** - obsolete: git stores every `.sh` as 100755.

## Key Implementation Patterns

**Instance Isolation:**
- Each instance uses unique ports: base + N - 1 (instance 1: Flask 5000, WebSocket 8765, ZMQ 5555)
- Separate databases per instance: openalgo{N}.db, latency{N}.db, logs{N}.db (named by the installer); health.db, sandbox.db, historify.duckdb (upstream defaults, created by OpenAlgo inside the instance's own db/)
- Unique session/CSRF cookie names (session{N}, csrf_token{N}) to prevent cross-instance pollution
- Individual systemd services with separate Unix sockets. **Service names are derived from the domain, not the index**: `openalgo-<domain with dots as dashes>` (e.g. `fyers.simplifyed.in` → `openalgo-fyers-simplifyed-in`). See `SERVICE_NAME=` in multi-install.sh. `openalgo{N}` is the *directory* name under /var/python/openalgo-flask/ — `systemctl status openalgo2` will always report "unit could not be found".

**Broker Integration:**
- Broker list and XTS list come from upstream at install/update time (see "Add support for a new broker")
- XTS brokers are also asked for market data API credentials
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

**.env Updates (oa-update.sh):**
- Every update rebuilds `.env` from the new `.sample.env`, so new settings appear
- Every old value is overlaid on top (ports, broker, credentials, keys, cookies, custom variables not in the template), except `ENV_CONFIG_VERSION` and the Historify path keys, which track upstream
- `VALID_BROKERS` is then taken from `.sample.env`; `OPENALGO_WORKER_CLASS = 'gthread'` is added if `.env` doesn't choose

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

**Add support for a new broker:** nothing to do. The broker list comes from upstream's `.sample.env` (`VALID_BROKERS`): installers fetch it from GitHub for the selected branch before validating (the hardcoded `VALID_BROKERS` in multi-install.sh/quick-setup.sh is only an offline fallback), and `oa-update.sh` re-syncs each instance's `.env` from the freshly pulled `.sample.env`. XTS brokers (which also need market data credentials) are read from https://docs.openalgo.in/connect-brokers/brokers.md - any broker whose display name there contains "XTS" - and added to the built-in `XTS_BROKERS` list, which acts as a floor (the page does not label `ibulls`, whose plugin still reads `BROKER_API_KEY_MARKET`). Offline, the built-in list is used.

**Debug installation failures:**
1. Check latest log: `tail -f logs/install_multi_*.log`
2. Verify systemd service: `sudo systemctl status openalgo-<domain-with-dashes>`
   (find it with `systemctl list-units 'openalgo-*'` — NOT `openalgo<N>`, that's the directory name)
3. Check Nginx config: `sudo nginx -t`
4. View Flask app logs: `sudo journalctl -u openalgo-<domain-with-dashes> -n 50`

**Monitor instance health:**
1. Read-only report: `sudo oa status` (or `oa status openalgo1`); exit codes for alerting
2. Check and fix databases + services: `sudo oa repair`

**Backup before major changes:**
1. Quick backup: `sudo ./oa-backup.sh all quick`
2. Full backup: `sudo ./oa-backup.sh all full`
3. List backups: `sudo ./oa-backup.sh list`

**Update instances safely:**
1. Preview: `sudo ./oa-update.sh dry-run`
2. One instance first, outside market hours: `sudo oa update openalgo1`
3. Then all: `sudo oa update` (newest release; `--main` for tip of main)
4. Rollback if needed: `sudo oa rollback /tmp/openalgo_backup_<inst>_<ts> openalgo1` (printed by the update)

**Modify port allocation strategy:**
Update the `FLASK_PORT=`/`WS_PORT=`/`ZMQ_PORT=` formulas in the instance loop of multi-install.sh

## Web server: gthread via upstream's launcher

Since OpenAlgo 2.0.2.7, systemd starts gunicorn through upstream's `install/openalgo-gunicorn.sh`, which reads `OPENALGO_WORKER_CLASS` from `.env` at every start (gthread: 64 threads, `install/lib/gunicorn_hooks.py` drain on stop, keep-alive 75). Upstream defaults to eventlet; this fleet runs gthread.

- **Installers** write `OPENALGO_WORKER_CLASS = 'gthread'` to `.env` and an ExecStart that calls the launcher (with an `# OPENALGO_LAUNCHER=1` marker that upstream's `switch-worker.sh` recognises). gunicorn/eventlet pins come from the instance's `requirements-nginx.txt` (currently `gunicorn>=25.0,<26`, `eventlet==0.41.2`).
- **oa-update.sh** adds `OPENALGO_WORKER_CLASS = 'gthread'` when `.env` doesn't choose (an explicit `'eventlet'` is respected), then, after its own health gate, runs upstream's `install/switch-worker.sh --service <svc> --yes --force`. That script backs up the unit, rewrites ExecStart, restarts, checks page + Socket.IO + running worker class, and restores the old unit itself on failure. It also fixes old nginx site configs once (adds the `/socket.io/` upgrade block, sends `Connection ""` on `/` — upstream issue #1807), restoring the original if `nginx -t` fails.
- **Switch one instance back:** set `OPENALGO_WORKER_CLASS = 'eventlet'` in its `.env` and restart. oa-update will not override it, and `oa-patch-known-issues.sh` re-applies the WhatsApp mitigation below for it.

## Known Upstream Issue: WhatsApp auto-start wedges the eventlet worker

**Applies to eventlet only.** `oa-patch-known-issues.sh` skips instances whose `.env` selects gthread, so WhatsApp auto-reconnects there.

**Symptom:** instance returns nginx 504 while `systemctl is-active` says `active` and the process is running. `oa-health-check.sh` reports "Socket accepts but does not respond - worker wedged".

**Cause:** `app.py` auto-starts the WhatsApp bot on a raw `threading.Thread`. That thread acquires an eventlet semaphore, and the hub (on another OS thread) then hits `greenlet.error: Cannot switch to a different thread` inside `fire_timers`, killing its timer/accept loop. Deterministic, ~6s after every boot, on any instance with a paired WhatsApp session. Confirmed 2026-07-27 on openalgo2 (fyers.simplifyed.in).

**Mitigation (automated):** `oa-patch-known-issues.sh` forces the `is_paired` gate in `app.py` false so the bot never auto-starts. The bot still starts manually from the UI; pairing and session blob are untouched. The patch is pattern-matched (not line-numbered), idempotent, self-skipping once upstream fixes the bug, and auto-reverted if the result doesn't compile.

It is applied automatically by `multi-install.sh` and `quick-setup.sh` (before first start) and by `oa-update.sh` (after `git pull`, which reverts it). `oa-update.sh` then gates success on `oa-repair.sh` (which ends with `oa-health-check.sh`'s end-to-end probe) rather than on `systemctl is-active`, which cannot detect a wedged worker.

**The real fix belongs upstream:** use `eventlet.spawn(_autostart_whatsapp_bot)` instead of `threading.Thread(...)` in `app.py`, or drop the eventlet worker class — gunicorn already warns eventlet is deprecated. Once upstream lands it, the patcher detects the change and skips automatically.

**Adding a future mitigation:** add a `patch_*` function to `oa-patch-known-issues.sh` following the rules in its header, and extend `--self-test` to cover it. Run `./oa-patch-known-issues.sh --self-test` to verify patch logic without touching any instance.

## Branding (oa-apply-branding.sh)

**Why it patches `dist`, not `src`:** OpenAlgo serves a pre-built React app. `blueprints/react_app.py` sets `FRONTEND_DIST = frontend/dist` and serves every route (`/`, `/assets/*`, `/images/*`, `/favicon.ico`, `/logo.png`, `/apple-touch-icon.png`) out of it, and `frontend/dist` is committed upstream. Editing `frontend/src` would require Node 24 + `npm ci` + `vite build` on every server on every update — hundreds of MB per instance and a real OOM risk on 2 GB boxes. So the overlay rewrites the built chunks directly. Nginx proxies everything to gunicorn, so nothing bypasses Flask and no static path escapes the overlay.

**What it changes:** display copy (`OpenAlgo` → `Simplifyed`), outbound links (the openalgo.in **homepage**, GitHub / X / YouTube → `$BRAND_URL`), bare hostnames rendered as visible text (the footer's `www.openalgo.in` label, a chart annotation — these are not URLs, so the link map misses them), the logo/favicon/apple-touch/chart-watermark image files, 16/32 px favicons and a `site.webmanifest` (under `/images/`, the only non-root static path Flask serves), the Home page header lockup, the `<title>`/description in `dist/index.html`, and the terminal banner strings in `app.py`.

**What it deliberately does NOT change:** `docs.openalgo.in` links and every `openalgo.in/<path>` page (`/learn`, `/discord`, `/roadmap` — OpenAlgo's docs and community, with no simplifyed.in equivalent; rewriting them sent users to dead simplifyed.in pages), the lowercase `openalgo` SDK package name, `OPENALGO_*` env vars, service names, DB paths, API fields, browser storage keys. Only capitalised `OpenAlgo` is treated as display copy — verified against upstream `main`, where all 137 occurrences in `frontend/src` are copy or comments, none are values.

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
| `unit` | Self-tests of oa-patch-known-issues, oa-apply-branding, oa-auto-update, oa-repair, openalgo-restart-api; broker list, health exit codes, update features |
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
- **Python packages**: uv (installed via snap), synced via `uv sync`; gunicorn + eventlet installed separately from the pins in `requirements-nginx.txt` (`uv sync` prunes them)
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
- WebSocket/ZMQ listen on 0.0.0.0 (installers set `WEBSOCKET_HOST`/`ZMQ_HOST`) but ufw denies them; clients reach them only through nginx (`/ws`)
- Firewall (ufw) allows SSH and 'Nginx Full', plus 8888 for the dashboard until oa-secure-admin.sh closes it
- `.env` is 600 (installers and every update)
- File permissions restrict instance directories to www-data user
- Keys directory (700 permissions) holds sensitive authentication data
- All scripts require sudo; no security bypass mechanisms
- The admin dashboard (`openalgo-restart-api.py`, port 8888 - Factory Reset, Reboot Server, per-instance restart/stop/start, SQL terminal) requires login: a styled page + PBKDF2-hashed credentials in `/etc/openalgo/admin-auth.json` + an in-memory session cookie, gating both `/` (manager) and `/monitor` (per-instance). Set/change credentials with `sudo python3 openalgo-restart-api.py --set-admin-password` (`oa install` generates one and shows it once; also via `api-manager.sh`'s menu and `oa-secure-admin.sh`). This intentionally replaces nginx `auth_basic` so the login prompt is stylable rather than the browser's native dialog - don't reintroduce `auth_basic` alongside it, that stacks two logins.

**Version Management:**
- OpenAlgo's version lives in `utils/version.py` (`VERSION = "x.y.z.w"`); releases are GitHub Releases with descriptive tag names (not semver)
- `ENV_CONFIG_VERSION` in `.sample.env` changes when the `.env` structure changes; updates copy it from `.sample.env`
