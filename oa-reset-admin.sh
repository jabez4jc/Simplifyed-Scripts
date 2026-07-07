#!/bin/bash
# oa-reset-admin.sh
# Reset the OpenAlgo admin user so the instance goes through first-time
# setup again. Use this when a user forgot their password and has neither
# a TOTP/QR reset configured nor working SMTP for password reset email.
#
# This deletes ALL rows from the `users` table in the instance's SQLite
# database. OpenAlgo will then prompt for a new admin account on next login.

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

BASE_DIR="/var/python/openalgo-flask"
BACKUP_DIR="/var/backups/openalgo"
INSTANCE=""
FORCE=0

usage() {
  cat <<EOF_USAGE
Usage: sudo $0 --instance NAME [--force]

Deletes all rows from the 'users' table for the given instance's SQLite
database, forcing OpenAlgo to prompt for first-time admin setup again.
The instance's systemd service is stopped before the change and restarted
after. A timestamped backup of the database file is taken first.

Options:
  --instance NAME   Instance directory name under $BASE_DIR (required)
  --force           Skip the interactive confirmation prompt
  -h, --help        Show this help

Examples:
  sudo $0 --instance openalgo1
  sudo $0 --instance openalgo-anand-simplifyed-in --force
EOF_USAGE
}

log_message() {
  local message="$1"
  local color="${2:-$NC}"
  echo -e "${color}${message}${NC}"
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_message "ERROR: Run as root (use sudo)." "$RED"
    exit 1
  fi
}

need_sqlite3() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    log_message "ERROR: sqlite3 is not installed. Install it with: apt-get install sqlite3" "$RED"
    exit 1
  fi
}

get_service_name() {
  local instance_dir="$1"
  local fallback_name="$2"
  local env_file="$instance_dir/.env"
  local domain=""

  if [ -f "$env_file" ]; then
    domain=$(grep -E "^DOMAIN\s*=" "$env_file" | head -1 | cut -d'=' -f2- | tr -d "' \"\r")
  fi

  if [ -n "$domain" ]; then
    echo "openalgo-${domain//./-}"
  elif [[ "$fallback_name" == openalgo* ]]; then
    echo "$fallback_name"
  else
    echo "openalgo$fallback_name"
  fi
}

find_users_db() {
  local db_dir="$1"
  local entry
  if [ ! -d "$db_dir" ]; then
    return 1
  fi
  for entry in "$db_dir"/*.db; do
    [ -e "$entry" ] || continue
    if sqlite3 "$entry" "SELECT name FROM sqlite_master WHERE type='table' AND name='users';" 2>/dev/null | grep -q users; then
      echo "$entry"
      return 0
    fi
  done
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance) INSTANCE="${2:?}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

need_root
need_sqlite3

if [[ -z "$INSTANCE" ]]; then
  log_message "ERROR: --instance is required" "$RED"
  usage
  exit 1
fi

ROOT="$BASE_DIR/$INSTANCE"
if [[ ! -d "$ROOT" ]]; then
  log_message "ERROR: Instance not found: $ROOT" "$RED"
  exit 1
fi

DB_FILE=$(find_users_db "$ROOT/db") || {
  log_message "ERROR: No database with a 'users' table found under $ROOT/db" "$RED"
  exit 1
}

USER_COUNT=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM users;")

log_message "Instance:  $INSTANCE" "$BLUE"
log_message "Database:  $DB_FILE" "$BLUE"
log_message "Users:     $USER_COUNT" "$BLUE"

if [[ "$USER_COUNT" -eq 0 ]]; then
  log_message "No users found; nothing to reset." "$YELLOW"
  exit 0
fi

if [[ "$FORCE" -ne 1 ]]; then
  log_message "⚠️  This deletes ALL users for '$INSTANCE' and forces first-time setup on next login." "$YELLOW"
  read -p "Type 'yes' to confirm: " confirm
  if [[ "$confirm" != "yes" ]]; then
    log_message "Aborted." "$YELLOW"
    exit 1
  fi
fi

SERVICE_NAME=$(get_service_name "$ROOT" "$INSTANCE")

mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/${INSTANCE}_users_reset_${TIMESTAMP}_$(basename "$DB_FILE")"
cp "$DB_FILE" "$BACKUP_FILE"
log_message "Backed up database to: $BACKUP_FILE" "$GREEN"

log_message "Stopping service: $SERVICE_NAME" "$BLUE"
systemctl stop "$SERVICE_NAME" 2>/dev/null || log_message "WARNING: could not stop $SERVICE_NAME (continuing)" "$YELLOW"

sqlite3 "$DB_FILE" "DELETE FROM users;"
log_message "Deleted all rows from users table." "$GREEN"

log_message "Starting service: $SERVICE_NAME" "$BLUE"
systemctl start "$SERVICE_NAME"

log_message "Done. '$INSTANCE' will prompt for first-time admin setup on next visit." "$GREEN"
