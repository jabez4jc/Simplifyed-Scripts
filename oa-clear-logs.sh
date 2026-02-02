#!/usr/bin/env bash
# oa-clear-logs.sh
# Combined log + safe cleanup for OpenAlgo instances.

set -euo pipefail

# === CONFIG ===
BASE_DIR="/var/python/openalgo-flask"
DAILY_RESTART_LOG="/var/log/openalgo-daily-restart.log"
TODAY="$(date +%F)"

APPLY=1
TMP_DAYS=1
VARTMP_DAYS=7
TMP_WIPE_ALL=0
TRUNCATE_MB=100
JOURNAL_MAX="200M"
JOURNAL_RETENTION="7day"
DO_APT=1
DO_DOCKER=1
LOGFILE="/var/log/openalgo-clear-safe.log"
LOCKFILE="/var/lock/openalgo-clear-safe.lock"
NO_CONFIRM=0
ONLY_INSTANCE=""

usage() {
  cat <<EOF
Usage: sudo $0 [--apply|--dry-run] [options]

Modes:
  --dry-run                Show what would be done
  --apply                  Execute actions (default)

Options:
  --instance NAME          Limit per-instance log cleanup to a single instance
  --yes                    Skip confirmation prompt
  --tmp-days N             Delete /tmp files older than N days (default: ${TMP_DAYS})
  --vartmp-days N          Delete /var/tmp files older than N days (default: ${VARTMP_DAYS})
  --tmp-wipe-all           Delete ALL contents of /tmp and /var/tmp (more aggressive)
  --truncate-mb N          Truncate active logs only if > N MB (default: ${TRUNCATE_MB})
  --journal-max 200M       Cap systemd journal to size (default: ${JOURNAL_MAX})
  --journal-retention 7day Retention cap (default: ${JOURNAL_RETENTION})
  --no-apt                 Skip apt cleanup
  --no-docker              Skip Docker prune even if Docker is installed
  -h, --help               Help
EOF
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    --instance) ONLY_INSTANCE="${2:?}"; shift 2 ;;
    --yes) NO_CONFIRM=1; shift ;;
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

echo "🧹 OpenAlgo Log Cleanup"
need_root
touch "$LOGFILE"
chmod 600 "$LOGFILE"

exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "ERROR: Another run is in progress (lock: $LOCKFILE)" >&2
  exit 1
fi

if [ ! -d "$BASE_DIR" ]; then
    echo "❌ No instances found in $BASE_DIR"
    exit 1
fi

if [[ "$NO_CONFIRM" -ne 1 ]]; then
    read -p "This will delete per-instance log files older than today and run safe cleanup. Continue? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "❌ Cancelled."
        exit 0
    fi
fi

if [[ -n "$ONLY_INSTANCE" ]]; then
    INSTANCES=("$ONLY_INSTANCE")
else
    INSTANCES=($(find "$BASE_DIR" -maxdepth 1 -type d -name "openalgo*" -printf "%f\n" 2>/dev/null | sort))
fi

if [ ${#INSTANCES[@]} -eq 0 ]; then
    echo "❌ No OpenAlgo instances installed."
    exit 1
fi

total_deleted=0
for inst in "${INSTANCES[@]}"; do
    for log_dir in "$BASE_DIR/$inst/log" "$BASE_DIR/$inst/logs"; do
        if [ -d "$log_dir" ]; then
            file_count=$(find "$log_dir" -type f -daystart -mtime +0 2>/dev/null | wc -l | tr -d ' ')
            dir_count=$(find "$log_dir" -mindepth 1 -maxdepth 1 -type d ! -name "$TODAY" 2>/dev/null | wc -l | tr -d ' ')
            if [ "$file_count" -gt 0 ] || [ "$dir_count" -gt 0 ]; then
                if [[ "$APPLY" -eq 1 ]]; then
                    find "$log_dir" -type f -daystart -mtime +0 -delete 2>/dev/null
                    find "$log_dir" -mindepth 1 -maxdepth 1 -type d ! -name "$TODAY" -exec rm -rf {} + 2>/dev/null
                else
                    echo "[DRY-RUN] Would clear $file_count file(s) and $dir_count folder(s) in $log_dir (kept $TODAY)"
                fi
                echo "✅ Cleared $file_count log file(s) and $dir_count log folder(s) in $log_dir (kept $TODAY)"
                total_deleted=$((total_deleted + file_count + dir_count))
            fi
        fi
    done
done

if [ -f "$DAILY_RESTART_LOG" ]; then
    if [[ "$APPLY" -eq 1 ]]; then
        rm -f "$DAILY_RESTART_LOG"
    else
        echo "[DRY-RUN] Would remove $DAILY_RESTART_LOG"
    fi
    echo "✅ Removed daily restart log: $DAILY_RESTART_LOG"
fi

log "===== START openalgo-clear-safe (APPLY=${APPLY}) ====="
run "df -hT /"

########################################
# 1) Journald vacuum + persistent caps
########################################
if has journalctl; then
  run "journalctl --disk-usage"
  run "journalctl --vacuum-size=${JOURNAL_MAX}"
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
if [[ -f /etc/logrotate.conf ]]; then
  run "logrotate -f /etc/logrotate.conf"
fi

run "rm -f /var/log/syslog.[0-9] /var/log/syslog.[0-9][0-9] /var/log/syslog.*.gz 2>/dev/null || true"
run "rm -f /var/log/auth.log.[0-9] /var/log/auth.log.[0-9][0-9] /var/log/auth.log.*.gz 2>/dev/null || true"
run "rm -f /var/log/kern.log.[0-9] /var/log/kern.log.[0-9][0-9] /var/log/kern.log.*.gz 2>/dev/null || true"
run "rm -f /var/log/ufw.log.[0-9] /var/log/ufw.log.[0-9][0-9] /var/log/ufw.log.*.gz 2>/dev/null || true"
run "rm -f /var/log/nginx/*.gz /var/log/nginx/*.[0-9] /var/log/nginx/*.[0-9][0-9] 2>/dev/null || true"
run "rm -f /var/log/cloud-init*.log.[0-9] /var/log/cloud-init*.log.*.gz 2>/dev/null || true"
run "rm -f /var/log/unattended-upgrades/*.gz /var/log/apt/*.gz 2>/dev/null || true"
run "rm -f /var/log/dpkg.log.*.gz /var/log/alternatives.log.*.gz 2>/dev/null || true"

########################################
# 3) Truncate active logs if oversized
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
# 4) Crash + core dumps
########################################
run "rm -f /var/crash/* 2>/dev/null || true"
run "rm -f /var/lib/systemd/coredump/* 2>/dev/null || true"

########################################
# 5) Temp cleanup (keep latest update log)
########################################
latest_update_log=$(ls -t /tmp/update_*.log 2>/dev/null | head -n 1)
if [[ "$TMP_WIPE_ALL" -eq 1 ]]; then
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
# 6) APT cleanup
########################################
if [[ "$DO_APT" -eq 1 ]] && has apt-get; then
  run "apt-get -y autoremove --purge"
  run "apt-get -y autoclean"
  run "apt-get -y clean"
  run "rm -rf /var/lib/apt/lists/*"
else
  log "APT cleanup skipped."
fi

########################################
# 7) Python/pip caches
########################################
run "rm -rf /root/.cache/pip 2>/dev/null || true"

if [[ -d /home ]]; then
  for u in /home/*; do
    [[ -d "$u" ]] || continue
    run "rm -rf '$u/.cache/pip' 2>/dev/null || true"
  done
fi

########################################
# 8) Docker prune
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

if [ "$total_deleted" -eq 0 ]; then
    echo "ℹ️  No per-instance log files found to delete."
else
    echo "✅ Cleanup complete. Deleted $total_deleted file(s)/folder(s)."
fi
