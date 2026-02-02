#!/usr/bin/env bash
# oa-invalidate-session.sh
# Invalidate OpenAlgo session using instance ORM logic.

set -euo pipefail

BASE_DIR="/var/python/openalgo-flask"
INSTANCE=""

usage() {
  cat <<EOF_USAGE
Usage: sudo $0 --instance NAME

Examples:
  sudo $0 --instance openalgo1
  sudo $0 --instance openalgo-anand-simplifyed-in
EOF_USAGE
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run as root (use sudo)." >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance) INSTANCE="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

need_root

if [[ -z "$INSTANCE" ]]; then
  echo "ERROR: --instance is required" >&2
  exit 1
fi

ROOT="$BASE_DIR/$INSTANCE"
if [[ ! -d "$ROOT" ]]; then
  echo "ERROR: Instance not found: $ROOT" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ROOT/.env"
set +a

python3 - <<'PY'
import sys
sys.path.insert(0, "openalgo")

from database.auth_db import Auth, upsert_auth
from database.master_contract_status_db import update_status

users = Auth.query.all()
if not users:
    print("No auth users found.")
    raise SystemExit(0)

for auth in users:
    upsert_auth(auth.name, "", "", revoke=True)
    print(f"Revoked: {auth.name}")

    if auth.broker:
        update_status(auth.broker, "pending", "Invalidated by admin script")
        print(f"Reset master contract status: {auth.broker}")
PY
