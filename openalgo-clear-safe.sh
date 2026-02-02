#!/usr/bin/env bash
# openalgo-clear-safe.sh
# "Clear everything safe" cleanup for Ubuntu OpenAlgo instances.
# - Removes rotated logs and compressions
# - Truncates oversized active logs safely (keeps file handles)
# - Vacuums systemd-journald logs
# - Cleans apt caches + orphan packages
# - Cleans /tmp and /var/tmp (age-based by default; optional wipe)
# - Clears crash/core dumps
# - Clears pip caches (root + users)
# - If Docker exists, prunes it (future-proof) unless disabled

set -euo pipefail

APPLY=0
TMP_DAYS=1
VARTMP_DAYS=7
TMP_WIPE_ALL=0
TRUNCATE_MB=100
JOURNAL_MAX="200M"         # deterministic
JOURNAL_RETENTION="7day"   # prevention
DO_APT=1
DO_DOCKER=1                # auto prune if docker exists (your request)
LOGFILE="/var/log/openalgo-clear-safe.log"
LOCKFILE="/var/lock/openalgo-clear-safe.lock"

usage() {
  cat <<EOF_USAGE
Usage: sudo $0 [--apply|--dry-run] [options]

Modes:
  --dry-run                Show what would be done (default)
  --apply                  Execute actions

Options:
  --tmp-days N             Delete /tmp files older than N days (default: ${TMP_DAYS})
  --vartmp-days N          Delete /var/tmp files older than N days (default: ${VARTMP_DAYS})
  --tmp-wipe-all           Delete ALL contents of /tmp and /var/tmp (more aggressive)
  --truncate-mb N          Truncate active logs only if > N MB (default: ${TRUNCATE_MB})
  --journal-max 200M       Cap systemd journal to size (default: ${JOURNAL_MAX})
  --journal-retention 7day Retention cap (default: ${JOURNAL_RETENTION})
  --no-apt                 Skip apt cleanup
  --no-docker              Skip Docker prune even if Docker is installed
  -h, --help               Help

Examples:
  sudo $0 --dry-run
  sudo $0 --apply
  sudo $0 --apply --truncate-mb 50 --journal-max 150M
  sudo $0 --apply --tmp-wipe-all
EOF_USAGE
}

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE" >/dev/null; }
say() { echo "$*"; }

run() {
  local cmd="$*"
  if [[ "$APPLY" -eq 1 ]]; then
    log "RUN: $cmd"
    bash -lc "$cmd" >>"$LOGFILE" 2>&1 || true
  else
    log "DRY: $cmd"
    echo "[DRY-RUN] $cmd"
  fi
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run as root (use sudo)." >&2
    exit 1
  fi
}

has() { command -v "$1" >/dev/null 2>&1; }

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    --tmp-days) TMP_DAYS="${2:?}"; shift 2 ;;
    --vartmp-days) VARTMP_DAYS="${2:?}"; shift 2 ;;
    --tmp-wipe-all) TMP_WIPE_ALL=1; shift ;;
    --truncate-mb) TRUNCATE_MB="${2:?}"; shift 2 ;;
    --journal-max) JOURNAL_MAX="${2:?}"; shift 2 ;;
    --journal-retention) JOURNAL_RETENTION="${2:?}"; shift 2 ;;
    --no-apt) DO_APT=0; shift ;;
    --no-docker) DO_DOCKER=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

need_root
touch "$LOGFILE"
chmod 600 "$LOGFILE"

# Lock to prevent concurrent runs
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "ERROR: Another run is in progress (lock: $LOCKFILE)" >&2
  exit 1
fi

log "===== START openalgo-clear-safe (APPLY=${APPLY}) ====="
run "df -hT /"

########################################
# 1) Journald vacuum + persistent caps
########################################
if has journalctl; then
  run "journalctl --disk-usage"
  run "journalctl --vacuum-size=${JOURNAL_MAX}"

  # Set persistent journald caps (prevents regrowth) - safe on servers
  run "mkdir -p /etc/systemd/journald.conf.d"
  run "cat > /etc/systemd/journald.conf.d/99-openalgo-limits.conf << 'EOF'
[Journal]
SystemMaxUse=${JOURNAL_MAX}
RuntimeMaxUse=100M
MaxRetentionSec=${JOURNAL_RETENTION}
EOF"
  run "systemctl restart systemd-journald"
else
  log "journalctl not found; skipping journald vacuum."
fi

########################################
# 2) Rotate logs once, then delete rotated logs
########################################
# Forcing logrotate makes sure big active logs are rotated properly first.
if [[ -f /etc/logrotate.conf ]]; then
  run "logrotate -f /etc/logrotate.conf"
fi

# Delete rotated logs (safe). Explicitly avoid utmp/wtmp/btmp/lastlog.
# Targets common offenders: syslog/auth/kern/ufw + nginx + cloud-init + unattended upgrades.
run "rm -f /var/log/syslog.[0-9] /var/log/syslog.[0-9][0-9] /var/log/syslog.*.gz 2>/dev/null || true"
run "rm -f /var/log/auth.log.[0-9] /var/log/auth.log.[0-9][0-9] /var/log/auth.log.*.gz 2>/dev/null || true"
run "rm -f /var/log/kern.log.[0-9] /var/log/kern.log.[0-9][0-9] /var/log/kern.log.*.gz 2>/dev/null || true"
run "rm -f /var/log/ufw.log.[0-9] /var/log/ufw.log.[0-9][0-9] /var/log/ufw.log.*.gz 2>/dev/null || true"
run "rm -f /var/log/nginx/*.gz /var/log/nginx/*.[0-9] /var/log/nginx/*.[0-9][0-9] 2>/dev/null || true"
run "rm -f /var/log/cloud-init*.log.[0-9] /var/log/cloud-init*.log.*.gz 2>/dev/null || true"
run "rm -f /var/log/unattended-upgrades/*.gz /var/log/apt/*.gz 2>/dev/null || true"
run "rm -f /var/log/dpkg.log.*.gz /var/log/alternatives.log.*.gz 2>/dev/null || true"

########################################
# 3) Truncate active logs if oversized (safe with running services)
########################################
truncate_if_big() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local mb
  mb=$(du -m "$f" | awk '{print $1}')
  if [[ "$mb" -ge "$TRUNCATE_MB" ]]; then
    run "truncate -s 0 '$f'"
  else
    log "SKIP truncate: $f is ${mb}MB (< ${TRUNCATE_MB}MB)"
  fi
}

truncate_if_big /var/log/syslog
truncate_if_big /var/log/auth.log
truncate_if_big /var/log/kern.log
truncate_if_big /var/log/ufw.log
truncate_if_big /var/log/nginx/access.log
truncate_if_big /var/log/nginx/error.log

########################################
# 4) Crash + core dumps (safe)
########################################
run "rm -f /var/crash/* 2>/dev/null || true"
run "rm -f /var/lib/systemd/coredump/* 2>/dev/null || true"

########################################
# 5) Temp cleanup (age-based default; optional wipe)
########################################
latest_update_log=$(ls -t /tmp/update_*.log 2>/dev/null | head -n 1)
if [[ "$TMP_WIPE_ALL" -eq 1 ]]; then
  # Aggressive: can disrupt rare apps that misuse /tmp; use when you want maximum cleanup.
  if [[ -n "$latest_update_log" ]]; then
    run "find /tmp -mindepth 1 -xdev ! -path '${latest_update_log}' -print -delete 2>/dev/null || true"
  else
    run "find /tmp -mindepth 1 -xdev -print -delete 2>/dev/null || true"
  fi
  run "find /var/tmp -mindepth 1 -xdev -print -delete 2>/dev/null || true"
else
  if [[ -n "$latest_update_log" ]]; then
    run "find /tmp -mindepth 1 -xdev -mtime +${TMP_DAYS} ! -path '${latest_update_log}' -print -delete 2>/dev/null || true"
  else
    run "find /tmp -mindepth 1 -xdev -mtime +${TMP_DAYS} -print -delete 2>/dev/null || true"
  fi
  run "find /var/tmp -mindepth 1 -xdev -mtime +${VARTMP_DAYS} -print -delete 2>/dev/null || true"
fi

########################################
# 6) APT cleanup (safe)
########################################
if [[ "$DO_APT" -eq 1 ]] && has apt-get; then
  run "apt-get -y autoremove --purge"
  run "apt-get -y autoclean"
  run "apt-get -y clean"
  # apt lists are safe to clear (will be re-fetched on apt update)
  run "rm -rf /var/lib/apt/lists/*"
else
  log "APT cleanup skipped."
fi

########################################
# 7) Python/pip caches (safe; improves disk usage)
########################################
# Root pip cache
run "rm -rf /root/.cache/pip 2>/dev/null || true"

# User pip caches under /home
if [[ -d /home ]]; then
  for u in /home/*; do
    [[ -d "$u" ]] || continue
    run "rm -rf '$u/.cache/pip' 2>/dev/null || true"
  done
fi

########################################
# 8) Docker prune (future-proof): run only if Docker exists and not disabled
########################################
if [[ "$DO_DOCKER" -eq 1 ]] && has docker; then
  run "docker system df"
  run "docker system prune -af"
  run "docker builder prune -af"
  run "docker volume prune -f"
else
  log "Docker prune skipped (docker not installed or disabled)."
fi

########################################
# Final report
########################################
run "sync"
run "df -hT /"
log "===== END openalgo-clear-safe ====="

say
say "Done."
say "Log: $LOGFILE"
if [[ "$APPLY" -eq 0 ]]; then
  say "This was DRY-RUN. Re-run with: sudo $0 --apply"
fi
