# OpenAlgo Fleet Manager — Build Plan

## 1. What this is

A standalone web app that manages OpenAlgo instances across **multiple servers**, each of which already runs the scripts in this repo (`multi-install.sh`, `oa-health-check.sh`, `oa-restart.sh`, `oa-backup.sh`, `oa-update.sh`, `openalgo-restart-api.py` on port 8888). The Fleet Manager is a *new, separate* repo/app — it does not modify anything in this repo, it consumes it.

Two integration paths, used for different jobs:

- **Per-server admin API** (`openalgo-restart-api.py`, already running on `:8888` on every server) — used for day-2 operations: list instances, health, restart/stop/start, logs, update, reboot. Read/write over HTTPS.
- **SSH to the target server** — used only for things the admin API can't do: bootstrapping a brand-new server (installing prerequisites, running `multi-install.sh`) and adding a new instance to an existing server.

Do not reimplement instance logic in the Fleet Manager. It is an aggregator + orchestrator over the existing scripts and API, not a replacement for them.

## 2. Confirmed existing contract (read from `openalgo-restart-api.py` in this repo)

Auth: **cookie/session, not API-key**. `POST /login-submit` (form-encoded `username`/`password`) → sets `oa_session` cookie (`SESSION_TTL_SECONDS` lifetime). Every other endpoint requires that cookie; there is no bearer-token/API-key mode today.

```
GET  /api/instances              list of instances + basic state
GET  /api/status                 aggregate status
GET  /api/health                 aggregate health
GET  /health                     liveness (no auth path assumed—verify)
GET  /api/logs/<instance>
GET  /api/broker-status/<instance>
GET  /api/scripts-status
GET  /api/terminal/dbs
GET  /api/jobs/<job_id>          poll async job status

POST /login-submit
POST /api/restart-all
POST /api/restart-instance
POST /api/stop-instance
POST /api/start-instance
POST /api/reboot-server
POST /api/health-check
POST /api/update
POST /api/scripts-status
POST /api/terminal/run
```

**Implication for the Fleet Manager:** for each registered server it must do a real form login (store `username`/`password`, or better, mint a dedicated fleet-manager admin account per server via `--set-admin-password`), keep the session cookie warm, and re-login on 401/expiry. Store credentials encrypted at rest (see §6).

Before coding starts, the build agent should re-run this same grep against the current `openalgo-restart-api.py` on a live server to confirm the endpoint list hasn't drifted, and check whether `/api/jobs/<id>` is the async pattern used by `/api/update` and `/api/health-check` (looks like it, given a job-poll endpoint exists) — the UI should poll that instead of blocking.

## 3. Scope by phase

**Phase 1 — Read-only fleet dashboard**
Register servers, poll each one's admin API on an interval, cache into local DB, render one dashboard: all servers × all instances, status/health/broker-auth at a glance.

**Phase 2 — Actions**
Proxy restart / stop / start / update / health-check / logs-view through to the right server's admin API. Async jobs tracked via `/api/jobs/<id>` polling, surfaced as a live log/status panel.

**Phase 3 — Remote provisioning (SSH)**
- Add a new instance to an existing, already-provisioned server: SSH in, run `multi-install.sh` (see §7 for the non-interactive gap this exposes).
- Onboard a brand-new bare server: SSH in, run prerequisite bootstrap, then `multi-install.sh`.
- Trigger `oa-update.sh`, `oa-backup.sh`, `oa-patch-known-issues.sh --self-test` remotely where the admin API doesn't cover them.

**Phase 4 — Polish**
Audit log of every action taken (who did what, on which server/instance, when), backup status visibility (surface `oa-backup.sh list` output), basic alerting (webhook/email when a poll finds a wedged/critical instance), RBAC if more than one human ever uses this (skip until actually needed — YAGNI).

Build phases 1–2 first and get them running for real before starting phase 3; provisioning is the highest-risk, highest-blast-radius part (it runs root-level scripts on remote boxes) and should be built once the read/act loop is proven.

## 4. Tech stack

- **Backend:** Python, FastAPI. Matches this repo's language, and the team already reads/writes Python/bash comfortably.
- **DB:** Postgres, provisioned as a Coolify managed resource (not SQLite — this app will run as a Coolify container and Coolify makes attaching Postgres a one-click resource; a container filesystem is not a place to keep a growing inventory/audit-log DB across redeploys).
- **Frontend:** Server-rendered Jinja2 templates + HTMX + Alpine.js for interactivity (live status polling, action buttons, job log tail). No React/Vite build pipeline — this is an internal ops dashboard, not a product UI; a build step is unrequested complexity here.
- **Background polling:** APScheduler in-process (interval job hitting every registered server's admin API). No separate worker/queue service — single Coolify container with an in-process scheduler is enough at "several servers" scale. Revisit only if poll volume or SSH job concurrency actually becomes a bottleneck.
- **SSH:** Paramiko, for the provisioning phase only.
- **Secrets encryption:** `cryptography` (Fernet), key supplied via Coolify env var, never committed.
- **Auth (Fleet Manager's own login, not per-server):** same shape as `openalgo-restart-api.py` already uses — PBKDF2-hashed credentials + signed session cookie. Reuse that pattern rather than inventing a new one or pulling in a full auth framework for a single-admin tool.

## 5. Data model (Postgres)

```
servers
  id, name, base_url (https://host:8888), ssh_host, ssh_port, ssh_user,
  ssh_key_encrypted, admin_username, admin_password_encrypted,
  created_at, last_seen_at, notes

instances            -- cache, refreshed by the poller; source of truth stays the server
  id, server_id (fk), instance_name, domain, broker, flask_port,
  status, health_status, env_version, last_polled_at, raw_json

provisioning_jobs
  id, server_id (fk), job_type (new_instance | new_server | update | backup | patch),
  params_json, status (queued|running|success|failed), log_text,
  started_at, finished_at, triggered_by

audit_log
  id, actor, action, server_id, instance_name, detail_json, created_at

fleet_users            -- Fleet Manager's own login, not the per-server admin creds
  id, username, password_hash, created_at
```

Keep `instances` as a cache table only — never treat it as authoritative; a poll failure should show "stale/unreachable," not silently keep old data marked healthy.

## 6. Security requirements

- Encrypt `ssh_key_encrypted` and `admin_password_encrypted` at rest (Fernet, key from env var set in Coolify, rotate-able).
- Fleet Manager's outbound SSH key should be a **dedicated keypair per Fleet Manager deployment**, added to each target server's `authorized_keys` during onboarding — not a reused personal key.
- Scope what the SSH user can do: either a dedicated deploy user with sudoers rules limited to the specific scripts in this repo, or accept it needs root/sudo (these scripts already require sudo throughout) but log every command executed to `audit_log` before running it.
- Never store broker API keys/secrets in Fleet Manager's own DB beyond what's needed to pass them through once during provisioning; don't display them again in the UI after entry (write-only field).
- All provisioning actions require confirmation in the UI (these run root-level, hard-to-reverse installs/reboots on remote boxes) — mirror this repo's own convention of confirmation prompts before destructive actions.
- TLS: run behind Coolify's built-in HTTPS/reverse proxy; don't terminate plaintext HTTP outside localhost.

## 7. Non-interactive prerequisites — DONE

Both gaps below are now fixed in this repo (verified with `bash -n`, `python -m py_compile`, and `tests/oa-test.sh --local`, 51/51 passing). The Fleet Manager's SSH provisioning path can rely on these directly — no pty/expect-style stdin wrapper needed.

**`multi-install.sh --config <file>`** — pass a config file instead of answering prompts:

```
CHANGE_TZ=y
BRANCH=main
INSTANCES=2
INSTANCE_1_DOMAIN=trade1.example.com
INSTANCE_1_BROKER=zerodha
INSTANCE_1_API_KEY=xxx
INSTANCE_1_API_SECRET=yyy
INSTANCE_2_DOMAIN=trade2.example.com
INSTANCE_2_BROKER=fivepaisaxts
INSTANCE_2_API_KEY=xxx
INSTANCE_2_API_SECRET=yyy
INSTANCE_2_MARKET_KEY=zzz        # only required for XTS brokers
INSTANCE_2_MARKET_SECRET=www
```

Usage: `sudo ./multi-install.sh --config /path/to/instances.env`. Same validation as the interactive prompts (domain format, broker allowlist, XTS market-credential requirement) — a missing/invalid field exits with an error instead of re-prompting, since there's no human on the other end. The Fleet Manager should write this file (e.g. to a temp path over SFTP), run the command over SSH, capture the log output, then delete the file (it contains broker secrets in plaintext on disk transiently).

**`openalgo-restart-api.py --set-admin-password --username <name> --password-stdin`** — reads the password from stdin instead of `getpass`, so it never appears in argv or shell history. Usage from the Fleet Manager over SSH:

```
printf '%s' "$GENERATED_PASSWORD" | sudo python3 /usr/local/bin/openalgo-restart-api.py --set-admin-password --username fleetmgr --password-stdin
```

Use this to provision a dedicated `fleetmgr` admin account per server (rather than reusing a human's admin login) during onboarding.

## 8. Deployment (Coolify)

- Single Dockerfile: FastAPI app + APScheduler in one process (uvicorn).
- Coolify resources: the app container + a managed Postgres instance, linked via `DATABASE_URL`.
- Env vars: `DATABASE_URL`, `FERNET_KEY`, `SESSION_SECRET`, `FLEET_ADMIN_BOOTSTRAP_PASSWORD` (first-run only, then force change).
- Persistent volume: none required if all state is in Postgres; SSH known_hosts cache can also live in Postgres or be re-verified per connection (prefer explicit host-key pinning per server row over `AutoAddPolicy`).
- Health endpoint (`/health`) for Coolify's own container health checks.

## 9. UI pages

1. **Login**
2. **Fleet overview** — table: server, instance count, healthy/warning/critical counts, last poll time
3. **Server detail** — instances table with per-instance action buttons (health, restart, update, logs), server-level actions (reboot, restart-all)
4. **Provisioning wizard** — pick existing server or "new server," form for domain/broker/credentials, submit → job created → live log tail via `/api/jobs/<id>`-style polling
5. **Jobs history** — past provisioning/update jobs, status, full log
6. **Audit log** — searchable/filterable action history

## 10. Explicit non-goals (skip unless it becomes a real need)

- Multi-user RBAC — single admin login is enough until proven otherwise.
- Real-time websockets — interval polling (HTMX `hx-trigger="every 30s"` or similar) is sufficient for an ops dashboard; don't add a websocket layer for this.
- A generic plugin system for "future broker types" or "future script types" — the script set in this repo is small and known; wire to it directly.
- Reimplementing health-check logic in Python — always call the server's own `oa-health-check.sh`/admin API and trust its exit code/output; don't build a parallel health model.

## 11. Handoff checklist for the build agent

- [ ] Confirm the `/api/*` endpoint list and auth flow against a live `openalgo-restart-api.py` instance (not just static grep) before coding the client.
- [x] `multi-install.sh --config` and `--set-admin-password --password-stdin` non-interactive modes are already implemented (§7) — use them as-is for Phase 3.
- [ ] Build Phase 1 and Phase 2 first, deployed and used for real, before touching SSH provisioning.
- [ ] Dedicated SSH keypair per Fleet Manager deployment; pin host keys per server row.
- [ ] Every provisioning/destructive action logged to `audit_log` and confirmed in the UI before execution.
