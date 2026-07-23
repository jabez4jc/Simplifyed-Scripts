#!/usr/bin/env bash
# oa-invalidate-session.sh
# Revoke a stale/invalid broker session for an OpenAlgo instance by writing
# directly to its SQLite auth db. This mirrors the read-side db discovery
# logic in openalgo-restart-api.py rather than booting the Flask app, since
# the app's package name (`openalgo`) can be shadowed by an unrelated PyPI
# package of the same name inside the instance venv.

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

python3 - "$ROOT" <<'PY'
import sqlite3
import sys
from pathlib import Path

root = Path(sys.argv[1])
db_dir = root / "db"

def has_table(db_file, table):
    try:
        conn = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True)
        row = conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)
        ).fetchone()
        conn.close()
        return bool(row)
    except sqlite3.Error:
        return False

def find_db_with_table(table):
    instance_num = root.name.replace("openalgo", "")
    candidates = []
    if instance_num.isdigit():
        candidates.append(db_dir / f"openalgo{instance_num}.db")
    candidates.append(db_dir / "openalgo.db")
    candidates.append(db_dir / "auth.db")
    for path in candidates:
        if path.exists() and has_table(path, table):
            return path
    if db_dir.is_dir():
        for entry in db_dir.iterdir():
            if entry.suffix == ".db" and has_table(entry, table):
                return entry
    return None

auth_db = find_db_with_table("auth")
if not auth_db:
    print("No auth database found.")
    raise SystemExit(0)

conn = sqlite3.connect(auth_db)
rows = conn.execute("SELECT name, broker FROM auth").fetchall()
if not rows:
    print("No auth users found.")
    raise SystemExit(0)

conn.execute("UPDATE auth SET is_revoked = 1, auth = '', feed_token = ''")
conn.commit()
for name, broker in rows:
    print(f"Revoked: {name}")

mc_db = find_db_with_table("master_contract_status")
if mc_db:
    mc_conn = sqlite3.connect(mc_db) if mc_db != auth_db else conn
    for name, broker in rows:
        if not broker:
            continue
        mc_conn.execute(
            "UPDATE master_contract_status SET is_ready = 0, message = ? WHERE broker = ?",
            ("Invalidated by admin script", broker),
        )
        print(f"Reset master contract status: {broker}")
    mc_conn.commit()
    if mc_conn is not conn:
        mc_conn.close()

conn.close()
PY
