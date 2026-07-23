#!/bin/bash
# oa-reset-admin.sh
# Reset the OpenAlgo admin user so the instance goes through first-time
# setup again. Use this when a user forgot their password and has neither
# a TOTP/QR reset configured nor working SMTP for password reset email.
#
# This deletes ALL rows from the `users` table (forces first-time admin
# setup) and, unless --skip-auth is passed, ALL rows from the `auth` table
# (clears broker login tokens/credentials so a fresh broker login is
# required) in the instance's SQLite database.
#
# Optionally also updates, in the instance's .env file:
#   - BROKER_API_KEY / BROKER_API_SECRET (and, for XTS-based brokers,
#     BROKER_API_KEY_MARKET / BROKER_API_SECRET_MARKET)
#   - REDIRECT_URL's broker segment, when switching to a different broker.
#     OpenAlgo determines the active broker from the path segment in
#     REDIRECT_URL (e.g. 'https://<domain>/<broker>/callback'), so this
#     must match one of the short names listed in VALID_BROKERS.
# so a full broker switch/credential rotation can be done in one step.

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
SKIP_AUTH=0
BROKER=""
BROKER_API_KEY=""
BROKER_API_SECRET=""
BROKER_API_KEY_MARKET=""
BROKER_API_SECRET_MARKET=""

usage() {
  cat <<EOF_USAGE
Usage: sudo $0 --instance NAME [--force] [--skip-auth] [--broker NAME]
       [--broker-api-key KEY] [--broker-api-secret SECRET]
       [--broker-api-key-market KEY] [--broker-api-secret-market SECRET]

Deletes all rows from the 'users' table for the given instance's SQLite
database, forcing OpenAlgo to prompt for first-time admin setup again.
Also deletes all rows from the 'auth' table (broker login tokens and
credentials) so the new admin has to re-enter broker credentials from the
profile section, unless --skip-auth is passed. The instance's systemd
service is stopped before the change and restarted after. A timestamped
backup of each affected database file (and the .env file, if it is
changed) is taken first.

If broker credential options are supplied, BROKER_API_KEY /
BROKER_API_SECRET (and the *_MARKET variants for XTS-based brokers) are
also updated in the instance's .env file before the service is restarted.

If --broker is supplied, the broker segment of REDIRECT_URL is updated
to that broker's short name (e.g. 'zerodha', 'angel', 'fyers', 'upstox')
so OpenAlgo picks up the new active broker; the value must be one of the
short names listed in the instance's VALID_BROKERS setting.

If none of --broker / --broker-api-* flags are given and --force is not
used, you will be interactively asked whether to switch brokers and/or
retain the existing broker credentials in .env or enter new ones now.

Options:
  --instance NAME                Instance directory name under $BASE_DIR (required)
  --force                        Skip the interactive confirmation prompt and the
                                  interactive broker/credential prompts (retains
                                  existing .env values unless --broker /
                                  --broker-api-* flags are also given)
  --skip-auth                    Only reset the users table; leave broker auth intact
  --broker NAME                   New broker short name; updates REDIRECT_URL
  --broker-api-key KEY            New BROKER_API_KEY value for .env
  --broker-api-secret SECRET      New BROKER_API_SECRET value for .env
  --broker-api-key-market KEY     New BROKER_API_KEY_MARKET value for .env (XTS brokers)
  --broker-api-secret-market SECRET  New BROKER_API_SECRET_MARKET value for .env (XTS brokers)
  -h, --help                     Show this help

Examples:
  sudo $0 --instance openalgo1
  sudo $0 --instance openalgo1 --broker zerodha --broker-api-key abc123 --broker-api-secret xyz789
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

find_table_db() {
  local db_dir="$1"
  local table_name="$2"
  local entry
  if [ ! -d "$db_dir" ]; then
    return 1
  fi
  for entry in "$db_dir"/*.db; do
    [ -e "$entry" ] || continue
    if sqlite3 "$entry" "SELECT name FROM sqlite_master WHERE type='table' AND name='$table_name';" 2>/dev/null | grep -qx "$table_name"; then
      echo "$entry"
      return 0
    fi
  done
  return 1
}

backup_file_copy() {
  local src_file="$1"
  local label="$2"
  mkdir -p "$BACKUP_DIR"
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_file="$BACKUP_DIR/${INSTANCE}_${label}_reset_${timestamp}_$(basename "$src_file")"
  cp "$src_file" "$backup_file"
  log_message "Backed up to: $backup_file" "$GREEN"
}

# Read KEY = 'value' (or "value") from an OpenAlgo .env file, quotes stripped.
# Returns 1 if the key is not present.
get_env_value() {
  local env_file="$1"
  local key="$2"
  local line

  line=$(grep -E "^${key}[[:space:]]*=" "$env_file" | head -1) || return 1
  [[ -z "$line" ]] && return 1
  line="${line#*=}"
  line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  line="${line%\'}"; line="${line#\'}"
  line="${line%\"}"; line="${line#\"}"
  printf '%s' "$line"
}

# Update KEY = 'value' in an OpenAlgo .env file. Returns 1 (without changing
# anything) if the key is not present in the file.
update_env_var() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  local escaped

  if ! grep -qE "^${key}[[:space:]]*=" "$env_file"; then
    return 1
  fi

  escaped=$(printf '%s' "$value" | sed -e 's/[\&|]/\\&/g')
  sed -i -E "s|^${key}[[:space:]]*=.*|${key} = '${escaped}'|" "$env_file"
  return 0
}

# Extract the broker short name from REDIRECT_URL, e.g.
# 'https://domain/zerodha/callback' -> 'zerodha'.
get_current_broker() {
  local env_file="$1"
  local redirect_url
  redirect_url=$(get_env_value "$env_file" "REDIRECT_URL") || return 1
  if [[ "$redirect_url" =~ ^(.*)/([A-Za-z0-9_]+)/callback/?$ ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

# Replace the broker segment of REDIRECT_URL with a new broker short name,
# preserving the domain and path. Returns 1 if REDIRECT_URL is missing or
# does not match the expected '.../<broker>/callback' shape.
update_redirect_url_broker() {
  local env_file="$1"
  local new_broker="$2"
  local redirect_url new_url

  redirect_url=$(get_env_value "$env_file" "REDIRECT_URL") || return 1
  if [[ "$redirect_url" =~ ^(.*)/([A-Za-z0-9_]+)/callback/?$ ]]; then
    new_url="${BASH_REMATCH[1]}/${new_broker}/callback"
    update_env_var "$env_file" "REDIRECT_URL" "$new_url"
    return 0
  fi
  return 1
}

is_valid_broker() {
  local valid_brokers="$1"
  local broker="$2"
  [[ -z "$valid_brokers" ]] && return 0
  [[ ",$valid_brokers," == *",$broker,"* ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance) INSTANCE="${2:?}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --skip-auth) SKIP_AUTH=1; shift ;;
    --broker) BROKER="${2:?}"; shift 2 ;;
    --broker-api-key) BROKER_API_KEY="${2:?}"; shift 2 ;;
    --broker-api-secret) BROKER_API_SECRET="${2:?}"; shift 2 ;;
    --broker-api-key-market) BROKER_API_KEY_MARKET="${2:?}"; shift 2 ;;
    --broker-api-secret-market) BROKER_API_SECRET_MARKET="${2:?}"; shift 2 ;;
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

ENV_FILE="$ROOT/.env"
CREDS_FROM_FLAGS=0
if [[ -n "$BROKER_API_KEY" || -n "$BROKER_API_SECRET" || -n "$BROKER_API_KEY_MARKET" || -n "$BROKER_API_SECRET_MARKET" ]]; then
  CREDS_FROM_FLAGS=1
fi
BROKER_FROM_FLAG=0
if [[ -n "$BROKER" ]]; then
  BROKER_FROM_FLAG=1
  BROKER=$(printf '%s' "$BROKER" | tr '[:upper:]' '[:lower:]')
fi

if [[ "$CREDS_FROM_FLAGS" -eq 1 || "$BROKER_FROM_FLAG" -eq 1 ]]; then
  if [[ ! -f "$ENV_FILE" ]]; then
    log_message "ERROR: .env not found for instance: $ENV_FILE" "$RED"
    exit 1
  fi
fi

if [[ "$BROKER_FROM_FLAG" -eq 1 ]]; then
  VALID_BROKERS_LIST=$(get_env_value "$ENV_FILE" "VALID_BROKERS" 2>/dev/null || echo "")
  if ! is_valid_broker "$VALID_BROKERS_LIST" "$BROKER"; then
    log_message "ERROR: '$BROKER' is not in VALID_BROKERS ($VALID_BROKERS_LIST)." "$RED"
    exit 1
  fi
fi

# Interactive mode (no --force, no --broker/--broker-api-* flags on the
# command line): let the operator choose whether to switch brokers and/or
# retain the existing broker credentials in .env or enter new ones now.
if [[ "$FORCE" -ne 1 && "$CREDS_FROM_FLAGS" -ne 1 && "$BROKER_FROM_FLAG" -ne 1 && -f "$ENV_FILE" ]]; then
  CURRENT_BROKER=$(get_current_broker "$ENV_FILE" 2>/dev/null || echo "")
  if [[ -n "$CURRENT_BROKER" ]]; then
    log_message "Current broker (from REDIRECT_URL): $CURRENT_BROKER" "$BLUE"
  fi
  read -p "Switch to a different broker? (y/N): " broker_choice
  if [[ "$broker_choice" =~ ^[Yy]$ ]]; then
    VALID_BROKERS_LIST=$(get_env_value "$ENV_FILE" "VALID_BROKERS" 2>/dev/null || echo "")
    if [[ -n "$VALID_BROKERS_LIST" ]]; then
      log_message "Valid brokers: ${VALID_BROKERS_LIST//,/, }" "$BLUE"
    fi
    read -p "Enter new broker short name (leave blank to keep current): " broker_input
    broker_input="$(printf '%s' "$broker_input" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [[ -z "$broker_input" ]]; then
      log_message "No broker entered; keeping current broker." "$YELLOW"
    elif ! is_valid_broker "$VALID_BROKERS_LIST" "$broker_input"; then
      log_message "ERROR: '$broker_input' is not in VALID_BROKERS; broker not changed." "$RED"
    else
      BROKER="$broker_input"
    fi
  fi

  read -p "Update broker API credentials in .env as well? (y/N): " creds_choice
  if [[ "$creds_choice" =~ ^[Yy]$ ]]; then
    read -p "New BROKER_API_KEY (leave blank to keep current): " BROKER_API_KEY
    read -r -s -p "New BROKER_API_SECRET (leave blank to keep current, input hidden): " BROKER_API_SECRET
    echo
    read -p "Is this an XTS-based broker requiring separate market data credentials? (y/N): " xts_choice
    if [[ "$xts_choice" =~ ^[Yy]$ ]]; then
      read -p "New BROKER_API_KEY_MARKET (leave blank to keep current): " BROKER_API_KEY_MARKET
      read -r -s -p "New BROKER_API_SECRET_MARKET (leave blank to keep current, input hidden): " BROKER_API_SECRET_MARKET
      echo
    fi
    if [[ -z "$BROKER_API_KEY" && -z "$BROKER_API_SECRET" && -z "$BROKER_API_KEY_MARKET" && -z "$BROKER_API_SECRET_MARKET" ]]; then
      log_message "No credential values entered; keeping existing broker credentials." "$YELLOW"
    fi
  else
    log_message "Keeping existing broker credentials in .env." "$BLUE"
  fi
fi

UPDATE_CREDS=0
if [[ -n "$BROKER_API_KEY" || -n "$BROKER_API_SECRET" || -n "$BROKER_API_KEY_MARKET" || -n "$BROKER_API_SECRET_MARKET" ]]; then
  UPDATE_CREDS=1
fi
ENV_CHANGED=0
if [[ "$UPDATE_CREDS" -eq 1 || -n "$BROKER" ]]; then
  ENV_CHANGED=1
fi

USERS_DB=$(find_table_db "$ROOT/db" "users") || {
  log_message "ERROR: No database with a 'users' table found under $ROOT/db" "$RED"
  exit 1
}

AUTH_DB=""
if [[ "$SKIP_AUTH" -ne 1 ]]; then
  AUTH_DB=$(find_table_db "$ROOT/db" "auth") || {
    log_message "WARNING: No database with an 'auth' table found under $ROOT/db; skipping broker credential reset." "$YELLOW"
    AUTH_DB=""
  }
fi

USER_COUNT=$(sqlite3 "$USERS_DB" "SELECT COUNT(*) FROM users;")
AUTH_COUNT=0
if [[ -n "$AUTH_DB" ]]; then
  AUTH_COUNT=$(sqlite3 "$AUTH_DB" "SELECT COUNT(*) FROM auth;")
fi

log_message "Instance:   $INSTANCE" "$BLUE"
log_message "Users DB:   $USERS_DB" "$BLUE"
log_message "Users:      $USER_COUNT" "$BLUE"
if [[ -n "$AUTH_DB" ]]; then
  log_message "Auth DB:    $AUTH_DB" "$BLUE"
  log_message "Auth rows:  $AUTH_COUNT" "$BLUE"
fi
if [[ -n "$BROKER" ]]; then
  log_message "Broker:     REDIRECT_URL will be switched to '$BROKER'" "$BLUE"
fi
if [[ "$UPDATE_CREDS" -eq 1 ]]; then
  log_message "Env file:   $ENV_FILE (broker credentials will be updated)" "$BLUE"
fi

if [[ "$USER_COUNT" -eq 0 && "$AUTH_COUNT" -eq 0 && "$ENV_CHANGED" -eq 0 ]]; then
  log_message "No users or broker auth rows found, and no broker/credential update requested; nothing to do." "$YELLOW"
  exit 0
fi

if [[ "$FORCE" -ne 1 ]]; then
  if [[ -n "$AUTH_DB" ]]; then
    log_message "⚠️  This deletes ALL users AND broker auth/login tokens for '$INSTANCE'. First-time setup and a fresh broker login will be required." "$YELLOW"
  else
    log_message "⚠️  This deletes ALL users for '$INSTANCE' and forces first-time setup on next login." "$YELLOW"
  fi
  if [[ -n "$BROKER" ]]; then
    log_message "⚠️  This will also switch the active broker to '$BROKER' in $ENV_FILE." "$YELLOW"
  fi
  if [[ "$UPDATE_CREDS" -eq 1 ]]; then
    log_message "⚠️  This will also overwrite broker API credentials in $ENV_FILE." "$YELLOW"
  fi
  read -p "Type 'yes' to confirm: " confirm
  if [[ "$confirm" != "yes" ]]; then
    log_message "Aborted." "$YELLOW"
    exit 1
  fi
fi

SERVICE_NAME=$(get_service_name "$ROOT" "$INSTANCE")

if [[ "$USER_COUNT" -gt 0 ]]; then
  backup_file_copy "$USERS_DB" "users"
fi
if [[ -n "$AUTH_DB" && "$AUTH_COUNT" -gt 0 && "$AUTH_DB" != "$USERS_DB" ]]; then
  backup_file_copy "$AUTH_DB" "auth"
fi
if [[ "$ENV_CHANGED" -eq 1 ]]; then
  backup_file_copy "$ENV_FILE" "env"
fi

log_message "Stopping service: $SERVICE_NAME" "$BLUE"
systemctl stop "$SERVICE_NAME" 2>/dev/null || log_message "WARNING: could not stop $SERVICE_NAME (continuing)" "$YELLOW"

if [[ "$USER_COUNT" -gt 0 ]]; then
  sqlite3 "$USERS_DB" "DELETE FROM users;"
  log_message "Deleted all rows from users table." "$GREEN"
fi

if [[ -n "$AUTH_DB" && "$AUTH_COUNT" -gt 0 ]]; then
  sqlite3 "$AUTH_DB" "DELETE FROM auth;"
  log_message "Deleted all rows from auth table (broker credentials cleared)." "$GREEN"
fi

if [[ -n "$BROKER" ]]; then
  if update_redirect_url_broker "$ENV_FILE" "$BROKER"; then
    log_message "Updated REDIRECT_URL broker segment to '$BROKER'." "$GREEN"
  else
    log_message "WARNING: Could not update REDIRECT_URL (missing or unexpected format); update it manually to end in '/$BROKER/callback'." "$YELLOW"
  fi
fi

if [[ "$UPDATE_CREDS" -eq 1 ]]; then
  if [[ -n "$BROKER_API_KEY" ]]; then
    if update_env_var "$ENV_FILE" "BROKER_API_KEY" "$BROKER_API_KEY"; then
      log_message "Updated BROKER_API_KEY in .env." "$GREEN"
    else
      log_message "WARNING: BROKER_API_KEY not found in .env; skipped." "$YELLOW"
    fi
  fi
  if [[ -n "$BROKER_API_SECRET" ]]; then
    if update_env_var "$ENV_FILE" "BROKER_API_SECRET" "$BROKER_API_SECRET"; then
      log_message "Updated BROKER_API_SECRET in .env." "$GREEN"
    else
      log_message "WARNING: BROKER_API_SECRET not found in .env; skipped." "$YELLOW"
    fi
  fi
  if [[ -n "$BROKER_API_KEY_MARKET" ]]; then
    if update_env_var "$ENV_FILE" "BROKER_API_KEY_MARKET" "$BROKER_API_KEY_MARKET"; then
      log_message "Updated BROKER_API_KEY_MARKET in .env." "$GREEN"
    else
      log_message "WARNING: BROKER_API_KEY_MARKET not found in .env (not an XTS broker template?); skipped." "$YELLOW"
    fi
  fi
  if [[ -n "$BROKER_API_SECRET_MARKET" ]]; then
    if update_env_var "$ENV_FILE" "BROKER_API_SECRET_MARKET" "$BROKER_API_SECRET_MARKET"; then
      log_message "Updated BROKER_API_SECRET_MARKET in .env." "$GREEN"
    else
      log_message "WARNING: BROKER_API_SECRET_MARKET not found in .env (not an XTS broker template?); skipped." "$YELLOW"
    fi
  fi
fi

log_message "Starting service: $SERVICE_NAME" "$BLUE"
systemctl start "$SERVICE_NAME"
systemctl reload nginx

if [[ -n "$AUTH_DB" ]]; then
  log_message "Done. '$INSTANCE' will prompt for first-time admin setup and require a fresh broker login on next visit." "$GREEN"
else
  log_message "Done. '$INSTANCE' will prompt for first-time admin setup on next visit." "$GREEN"
fi
if [[ "$ENV_CHANGED" -eq 1 ]]; then
  log_message "Broker/.env settings updated and service restarted to pick up the new values." "$GREEN"
fi
