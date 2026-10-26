# OpenAlgo Instance Management Scripts

A collection of simplified bash scripts for managing OpenAlgo trading platform instances on Ubuntu/Debian servers.

## Overview

These scripts automate the installation, configuration, and maintenance of one or more OpenAlgo instances running on a single server. Each instance can be configured for a different broker and domain, with independent Flask ports, WebSocket endpoints, and databases.

## Installation Requirements

- Ubuntu 20.04 LTS or later (Debian-based); tested on 24.04 and 26.04
- Root/sudo access
- Domain names with DNS pointing to your server
- Broker API credentials for each instance

## Quick Start

On a fresh Ubuntu server (DNS for your domains already pointing at it):

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/jabez4jc/Simplifyed-Scripts/main/install.sh)"
```

It installs the scripts at `/root/Simplifyed-Scripts`, adds the `oa` command, sets
up 4 GB swap (if none), the IST timezone, the admin dashboard on port 8888, and
OpenAlgo with Simplifyed branding.

It asks only what it cannot guess: how many instances (Enter = 1), then the
domain, broker, API key and secret for each (plus the market data key/secret for
XTS brokers). On the first install it then asks for the admin dashboard login
(username and password, used by the dashboard and every `/monitor` page) and an
optional domain for the dashboard (DNS must already point at the server; Enter
skips it and the dashboard stays on `http://<server-ip>:8888`). Change either
later with `oa admin`. Last, optional Telegram notices: create a bot with
@BotFather, send it any message, then paste its token (hidden; Enter skips) -
the chat ID is detected and a test message confirms it. Set up or change later
with `oa auto-update telegram`, or from the admin dashboard (Telegram button,
next to Change Password).

Use this exact command, not `curl ... | sudo bash`: on Ubuntu 25.10+ (sudo-rs)
the piped form cannot read your keyboard, so the installer stops and prints the
right command instead.

Options: `sudo bash -c "$(curl -fsSL .../install.sh)" _ --no-branding --swap 8`

On a server that already has instances, the same line only updates the scripts
and adds the `oa` command - it never installs anything. See
[Updating an Existing Server](#updating-an-existing-server).

## Everyday Commands

```bash
oa add                     # add more instances
oa update                  # update scripts, every instance (newest OpenAlgo release) and the admin dashboard
oa update openalgo2        # just one instance (--main: tip of main instead of a release)
oa update-scripts          # only the scripts + admin dashboard; no instance restarts (safe in market hours)
oa status                  # health check of every instance
oa repair                  # check databases + services and fix what is broken
oa restart [INSTANCE|all]  # restart instances (menu without an argument)
oa rollback BACKUP INST    # undo an update (code, dependencies, .env, databases)
oa backup | oa remove | oa brand | oa swap | oa admin
oa help
```

Every `oa` command first pulls the latest scripts from GitHub, so a script fix
reaches a server the next time you run any `oa` command - usually just
`oa update` (or `oa repair` to fix without updating OpenAlgo). Instances with
auto-update pick fixes up at 03:30 IST on their own.

## Self-Repair

After every install, update and rollback, each instance is checked
automatically (`oa repair` runs the same check on demand):

- **Databases**: every SQLite and DuckDB database is integrity-checked. A
  damaged one is moved to `db/damaged-<time>/` (deleted after 7 days) and the
  instance restarted, so OpenAlgo recreates it. After an update, a healthy copy
  from the pre-update backup is restored instead, so users, API keys and broker
  logins are kept. A database that is merely in use is never touched.
- **Ownership**: database files (including `-wal`/`-shm`) not owned by
  `www-data` are given back. Files left by a root process were the usual cause
  of a broken `sandbox.db` ("attempt to write a readonly database").
- **Orphaned databases**: a `.db`/`.duckdb` in `db/` that neither `.env` nor
  OpenAlgo's defaults point at (e.g. a stray `openalgo.db` next to
  `openalgo2.db`) is deleted, unless a process has it open.
- **Service**: enabled, running and answering requests; restarted only if not.
- **Disk**: at 85% full or more it clears logs, the journal, old temp files and
  `oa backup` archives older than 14 days, and lists what is still big.

Anything fixed, or still broken, is reported on Telegram if it is set up.

## Automatic Updates (opt-in)

New OpenAlgo **releases** (not every commit) can install themselves at 03:30 IST,
once a release has been public for 72 hours:

```bash
oa auto-update enable all                  # equity/F&O/MCX instances: daily at 03:30 IST
oa auto-update enable openalgo3 --sundays  # crypto instances: Sundays at 03:30 IST only
oa auto-update telegram                    # release notices + results on Telegram
oa auto-update status
```

Instances update one at a time. A failed update is rolled back automatically and
the rollout stops. A Telegram notice goes out when a release is first published
(with its install date and release notes - check them for behaviour changes),
after each run, and when `oa repair` fixes something or finds an instance still
broken. Off unless enabled; `oa auto-update disable INSTANCE` turns
it off.

The 8 AM IST daily restart is separate and also opt-in (`oa daily-restart`) -
do not enable it on crypto instances.

## Updating an Existing Server

1. **Once:** get the current scripts and the `oa` command with the install line
   above. On a server with instances it only updates `/root/Simplifyed-Scripts`.
2. **Once, if the instances were branded before `oa` existed:** `sudo oa brand all`.
   Updates re-brand only instances carrying the `.simplifyed-branding` marker;
   this brands every instance and marks it, with no restart needed (hard-refresh
   the browser). Skip it to keep instances on OpenAlgo's own branding, or brand
   one: `sudo oa brand /var/python/openalgo-flask/openalgo2`.
3. **Try one instance first, outside market hours:**
   ```bash
   sudo oa update openalgo1
   sudo oa status openalgo1
   ```
4. **Then the rest:** `sudo oa update`

`oa update` installs the newest OpenAlgo **release**; an instance already on newer
code from `main` is never moved backwards. `oa update --main` follows the tip of
`main` instead.

The first update of an older server also, each with its own checks:
- switches the instance to the **gthread** web server (upstream's launcher,
  64 request threads) - see [Web Server](#web-server);
- fixes the instance's nginx config (`/socket.io/` block, plain keep-alive);
- runs `oa repair`, which fixes database ownership and gives the health,
  sandbox and Historify databases back their own files (earlier installs
  pointed them at the main `openalgo<N>.db`).

Every update first backs up `.env`, the databases and the current code
version to `/tmp/openalgo_backup_<instance>_<time>` (the latest one per
instance) and prints the exact `oa rollback` command. `/tmp` is cleared on
reboot - for a copy that lasts, run `sudo oa backup all quick` first.
The copy leaves out Historify's DuckDB (re-downloadable market data, often
GBs); a rollback leaves that file as it is.

## Scripts (reference)

All scripts run as root and live in `/root/Simplifyed-Scripts`. `oa` covers the
everyday ones; each still works on its own (the admin dashboard and Fleet
Manager call them directly).

| Script | Run with | What it does |
|---|---|---|
| `install.sh` | one-line installer | Clones/updates the scripts, links `oa`, runs `oa install` on a new server |
| `oa.sh` | `oa ...` | The `oa` command: dispatches to the scripts below |
| `multi-install.sh` | `oa install`, `oa add` | Installs one or more instances (see below) |
| `oa-update.sh` | `oa update`, `oa rollback` | Updates instances; rollback |
| `oa-auto-update.sh` | `oa auto-update` | Opt-in automatic release installs at 03:30 IST |
| `oa-repair.sh` | `oa repair` | Checks databases + services, fixes what is broken |
| `oa-health-check.sh` | `oa status` | Read-only health report |
| `oa-backup.sh` | `oa backup` | Backups and restore |
| `oa-restart.sh` | `oa restart` | Restart one or all instances |
| `openalgo-restart-api.py` | `oa admin` | Admin dashboard + its HTTP API for other apps: docs at `https://<admin-domain>/api/docs`, OpenAPI at `/api/openapi.json` (both generated from the code; log in first) |
| `oa-uninstaller.sh` | `oa remove [INSTANCE] [--yes]` | Remove instances (service, files, nginx, certificate) - a verified full backup is taken first, and nothing is deleted without it. Also `POST /api/delete-instance` |
| `oa-apply-branding.sh` | `oa brand` | Simplifyed branding (applied automatically) |
| `oa-patch-known-issues.sh` | automatic | Mitigations for known upstream bugs |
| `oa-configure-swap.sh` | `oa swap [GB]` | Swap of any size (1-512 GB) |
| `update_swap_2gb.sh` | directly | Fixed 4 GB swap (the name is historical) |
| `setup-daily-restart.sh` | `oa daily-restart` | Opt-in 8 AM IST restart of all instances |
| `api-manager.sh` | `oa admin` | Admin dashboard setup and menu |
| `oa-secure-admin.sh` | `oa admin` → option 5 | Dashboard domain + HTTPS, close port 8888 |
| `oa-reset-admin.sh` | dashboard: Factory Reset | Forces first-time admin setup on an instance |
| `oa-invalidate-session.sh` | dashboard: Invalidate | Revokes a stale broker session |
| `oa-clear-logs.sh` | daily timer (03:10) | Log and temp-file cleanup |
| `quick-setup.sh` | directly | Older single-instance installer; `oa install` replaces it |
| `make-executable.sh` | directly | Not needed: git keeps the scripts executable |

### Installing (`oa install` / `multi-install.sh`)

Per instance: system packages, firewall, a clone of OpenAlgo in
`/var/python/openalgo-flask/openalgo<N>`, a Python venv (`uv`), the `.env`
(unique ports, cookies, databases and generated keys), nginx with a Let's
Encrypt certificate, a systemd service, branding, known-issue patches, and a
final `oa repair`. New instances are numbered after existing ones, so `oa add`
never overwrites anything.

`oa install` takes defaults for everything it can (IST timezone, branch `main`,
branding on). Options: `--no-branding`, `--swap GB`. Run directly,
`multi-install.sh` also asks for those.

Non-interactive (Fleet Manager): `multi-install.sh --config instances.env` - the
variables are listed at the top of the script.

### Updating (`oa update` / `oa-update.sh`)

For each instance: backup, stop, fast-forward the code (to a release tag with
`oa update`), install dependencies (`requirements-nginx.txt`, which also pins
gunicorn/eventlet), rebuild `.env` from the new `.sample.env` (new settings
appear; every existing value - ports, credentials, keys, cookies, your own
variables - is carried over; `ENV_CONFIG_VERSION` and the broker list follow
upstream), run upstream's migrations as `www-data`, re-apply
branding (marked instances only - see `oa brand all` above) and patches, start,
then `oa repair`. A failure exits non-zero.

```bash
sudo ./oa-update.sh                          # menu
sudo ./oa-update.sh openalgo1                # one instance (tip of main)
sudo ./oa-update.sh update-all               # all instances
sudo ./oa-update.sh dry-run                  # preview
sudo ./oa-update.sh rollback BACKUP_DIR openalgo1
```

Rollback restores the code version, dependencies, branding, `.env` and
databases from the backup, then runs `oa repair`.

### Health check (`oa status` / `oa-health-check.sh`)

Read-only: service, ports, `.env`, databases present, disk, venv, whether the
app actually answers on its socket, recent errors, permissions, and system-wide
nginx/firewall/swap/load.

```bash
sudo ./oa-health-check.sh all | system | openalgo1
```
Exit codes: `0` healthy, `1` warnings, `2` critical. Runs twice a day (07:00,
19:00) from a timer installed with the admin dashboard.

### Backups (`oa backup` / `oa-backup.sh`)

```bash
sudo oa backup all quick       # .env (GPG-encrypted if gpg is installed), databases, nginx + service files
sudo oa backup all full        # whole instance (without venv)
sudo oa backup single quick    # pick one instance
sudo oa backup list
sudo oa backup restore
sudo oa backup cleanup 30      # delete backups older than 30 days
```
Backups go to `/var/backups/openalgo` (override with `OA_BACKUP_DIR=...`).

### Swap

`oa install` creates 4 GB when the server has none. `sudo oa swap 8` (or
`oa-configure-swap.sh`) sets any size after checking free disk space.

### Daily restart (`oa daily-restart`)

Opt-in cron job restarting every instance at 8:00 AM IST
(`/usr/local/bin/openalgo-daily-restart.sh`, log
`/var/log/openalgo-daily-restart.log`). It restarts **all** instances - do not
enable it on a server with crypto instances. Change the time with
`sudo crontab -e`; remove the job by deleting its line there.

### Cleanup (`oa-clear-logs.sh`)

Installed as a daily 03:10 timer by the dashboard setup. Run by hand:
`sudo ./oa-clear-logs.sh --dry-run` to preview, `--instance NAME`, `--yes`
(see `--help` for the retention options).

### Factory reset and stale sessions

```bash
sudo ./oa-reset-admin.sh --instance openalgo1           # forgotten admin password: first-time setup again
sudo ./oa-invalidate-session.sh --instance openalgo1    # revoke a stale broker session
```
Both are also buttons on the dashboard. `--help` lists the options (e.g.
changing the broker or its API key during a reset).

## Admin Dashboard

`http://<server-ip>:8888` (or its own domain + HTTPS: `oa admin` → option 5),
plus a per-instance page at `https://<instance-domain>/monitor`. Both need the
admin login, which the first `oa install` asks for - change it with `oa admin`
→ Change Admin Password.

It shows each instance's service, broker login and master contract status, and
logs, and can restart/stop/start, update, health-check, invalidate a broker
session, factory-reset, run read-only SQL `SELECT`s, and reboot the server.
Its System card is live: CPU (per core, iowait, steal), memory, disks (usage,
inodes, I/O), network and the top processes with the service each belongs to,
streamed from `GET /api/telemetry/stream` (Server-Sent Events; one snapshot:
`GET /api/telemetry`).

Its HTTP API (`/api/...`) serves the dashboard itself; every endpoint except
`GET /health` requires the dashboard login session.

```bash
sudo systemctl status openalgo-restart-api
sudo journalctl -u openalgo-restart-api -f
```

## Web Server

Instances run gunicorn through upstream's `install/openalgo-gunicorn.sh`, which
reads `OPENALGO_WORKER_CLASS` from the instance's `.env` at every start. This
setup uses **gthread** (64 request threads, so one slow broker call no longer
holds up the app). To put one instance back on eventlet, set
`OPENALGO_WORKER_CLASS = 'eventlet'` in its `.env` and restart it; updates leave
that choice alone.

## Instance Management

```bash
oa status                                  # all instances
systemctl list-units 'openalgo-*'          # services
sudo journalctl -u openalgo-<domain> -f    # live log of one instance
sudo systemctl restart openalgo-<domain>
```
Service names come from the domain, dots as dashes: `fyers.example.com` →
`openalgo-fyers-example-com`. (`openalgo<N>` is the folder name, not a service.)

## Directory Structure

Each instance: `/var/python/openalgo-flask/openalgo<N>/`, with a domain-named
symlink next to it for easy identification.

- `.env` - settings and broker credentials (owner-only)
- `db/` - `openalgo<N>.db`, `latency<N>.db`, `logs<N>.db`, `health.db`,
  `sandbox.db`, `historify.duckdb` (created by OpenAlgo as needed);
  `damaged-<time>/` holds databases `oa repair` moved aside (kept 7 days)
- `venv/` - Python environment
- `strategies/`, `keys/` (700), `log/`, `tmp/`
- `.simplifyed-branding`, `.simplifyed-autoupdate` - markers: re-brand on
  update / auto-update schedule

Server-wide:
- `/root/Simplifyed-Scripts` - these scripts
- `/etc/openalgo/admin-auth.json` - dashboard login (hashed)
- `/etc/simplifyed/auto-update.conf` - Telegram settings (owner-only)
- `/var/log/oa-auto-update.log` - automatic update runs

## Configuration Details

### Instance Isolation

Each instance has its own `.env`, ports (instance 1: Flask 5000, WebSocket
8765, ZMQ 5555; each further instance +1), databases, session/CSRF cookie names
(`session<N>`/`csrf_token<N>`), gunicorn socket and systemd service.

### Brokers

The broker list is read from upstream's `.sample.env` at every install and
update, so new OpenAlgo brokers are available without changing these scripts.
XTS brokers (which also need a market data key and secret) are read from the
[OpenAlgo broker list](https://docs.openalgo.in/connect-brokers/brokers.md),
on top of a built-in list (`fivepaisaxts`, `compositedge`, `ibulls`, `iifl`,
`jainamxts`, `rmoney`, `wisdom`). Without internet access a built-in list is
used.

### SSL/TLS

Let's Encrypt certificates via certbot, renewed automatically; nginx terminates
TLS and proxies to each instance's gunicorn socket.

## Security Notes

- Broker credentials live in each instance's `.env` (mode 600, `www-data`).
- The firewall (ufw) allows only SSH and HTTP/HTTPS, plus port 8888 for the
  dashboard until `oa admin` → option 5 closes it. WebSocket and ZMQ listen on
  all interfaces but are reachable only through nginx.
- The dashboard password is stored PBKDF2-hashed.
- Telegram bot tokens are kept in a root-only file and never put on a command
  line.

## Logs

- Installs: `logs/install_multi_<time>.log` in the scripts folder
- Updates: `/tmp/update_<time>.log`
- Automatic updates: `/var/log/oa-auto-update.log`
- Instances: `journalctl -u openalgo-<domain>`

## Licence

OpenAlgo is AGPL-3.0. Rebranding does not remove its licence, copyright,
source-availability or legal-notice obligations.

## Support

For issues with OpenAlgo itself, see the
[OpenAlgo GitHub repository](https://github.com/marketcalls/openalgo).
