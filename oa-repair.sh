#!/bin/bash
# OpenAlgo Utility - verify instances and fix what is broken
#
# Runs automatically after every install, update and rollback; also `oa repair`.
# For each instance:
#   1. Databases: every SQLite file (PRAGMA quick_check) and DuckDB file (opened
#      read-only) in db/ or named in .env. "Locked"/"busy" means the app is
#      using it and is never treated as damage; anything ambiguous (e.g. a
#      DuckDB version mismatch) is reported and left alone.
#      A damaged database: the service is stopped and the file (with its
#      -wal/-shm/-journal) moved to db/damaged-<time>/. If the latest pre-update
#      backup holds a healthy copy, that copy is restored and migrations re-run
#      (keeps users, API keys, broker logins); otherwise OpenAlgo recreates the
#      database empty when it starts. damaged-* folders are deleted after 7 days.
#   2. Ownership: db/ files not owned by www-data (e.g. -wal/-shm left by a root
#      process) are handed back - the app cannot write them otherwise.
#   3. Service: enabled, running, and actually answering (oa-health-check.sh).
#      Restarted when needed, retried once, then reported with log lines.
# Repairs and failures are sent to Telegram when `oa auto-update telegram` is set up.
#
# Usage:
#   oa-repair.sh [all|INSTANCE]     (default: all)
#   oa-repair.sh --self-test
#
# Exit: 0 healthy, 1 repaired and now healthy, 2 still broken.

set -uo pipefail

BASE_DIR="/var/python/openalgo-flask"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TS=$(date +%Y%m%d_%H%M%S)
TELEGRAM_BOT_TOKEN=""; TELEGRAM_CHAT_ID=""
# shellcheck disable=SC1091
[ -r /etc/simplifyed/auto-update.conf ] && source /etc/simplifyed/auto-update.conf

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
say() { echo -e "${2:-}$1${NC}"; }

# Prints one line per database: STATUS<TAB>path<TAB>detail
# STATUS: OK | INUSE | MISSING | DAMAGED | UNKNOWN
# Args: an instance dir (discovers its databases) or explicit database files.
CHECKER='
import glob, os, re, sqlite3, sys

def discover(inst):
    paths = set(glob.glob(os.path.join(inst, "db", "*.db")) + glob.glob(os.path.join(inst, "db", "*.duckdb")))
    env = os.path.join(inst, ".env")
    if os.path.exists(env):
        for line in open(env, errors="ignore"):
            m = re.match(r"\s*[A-Z_]*(?:DATABASE_URL|DB_URL|DB_PATH|DUCKDB_PATH)\s*=\s*[\x27\"]?([^\x27\"#\s]+)", line)
            if not m:
                continue
            v = m.group(1)
            if v.startswith("sqlite:///"):
                v = v[len("sqlite:///"):]
            elif "://" in v:
                continue  # a database server, not a file on this machine
            paths.add(v if os.path.isabs(v) else os.path.join(inst, v))
    return sorted(paths)

def check(p):
    if not os.path.exists(p):
        return "MISSING", "not created yet"
    if os.path.getsize(p) == 0:
        return "DAMAGED", "empty file"
    if p.endswith(".duckdb"):
        try:
            import duckdb
        except ImportError:
            return "UNKNOWN", "duckdb module not available"
        try:
            con = duckdb.connect(p, read_only=True)
            con.execute("SELECT 1")
            con.close()
            return "OK", ""
        except Exception as e:
            low = str(e).lower()
            msg = str(e).splitlines()[0][:160]
            if "lock" in low:
                return "INUSE", msg
            if "not a valid duckdb" in low or "corrupt" in low or "checksum" in low:
                return "DAMAGED", msg
            return "UNKNOWN", msg
    try:
        con = sqlite3.connect("file:%s?mode=ro" % p, uri=True, timeout=10)
        rows = con.execute("PRAGMA quick_check(3)").fetchall()
        con.close()
        if rows == [("ok",)]:
            return "OK", ""
        return "DAMAGED", "; ".join(r[0] for r in rows)[:160]
    except sqlite3.OperationalError as e:
        low = str(e).lower()
        if "locked" in low or "busy" in low:
            return "INUSE", str(e)
        if "unable to open" in low or "disk i/o" in low or "readonly" in low:
            return "UNKNOWN", str(e)
        return "DAMAGED", str(e)
    except sqlite3.DatabaseError as e:  # "file is not a database", "malformed"
        return "DAMAGED", str(e)

args = sys.argv[1:]
paths = discover(args[0]) if len(args) == 1 and os.path.isdir(args[0]) else args
for p in paths:
    status, detail = check(p)
    print("%s\t%s\t%s" % (status, p, detail.replace("\t", " ").replace("\n", " ")))
'

check_dbs() {  # python, then dir or files
    local py="$1"; shift
    "$py" -c "$CHECKER" "$@"
}

service_name_of() {
    local domain
    domain=$(grep -E '^DOMAIN *=' "$1/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "' \"\r")
    if [ -n "$domain" ]; then echo "openalgo-${domain//./-}"; else basename "$1"; fi
}

telegram_send() {
    [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] || return 0
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" \
        | curl -s -m 20 -K - -o /dev/null --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$1"
}

FIXED=(); BROKEN=()

repair_instance() {
    local dir="$1" inst svc py restart=0 migrate=0 status path detail
    inst=$(basename "$dir"); svc=$(service_name_of "$dir")
    py="$dir/venv/bin/python"; [ -x "$py" ] || py=python3
    say "\n── $inst ($svc)" "$BLUE"

    # 1. Databases
    local damaged=()
    while IFS=$'\t' read -r status path detail; do
        case "$status" in
            OK)      say "  ✓ $(basename "$path")" "$GREEN" ;;
            INUSE)   say "  ✓ $(basename "$path") (in use by OpenAlgo)" "$GREEN" ;;
            MISSING) say "  · $(basename "$path"): not created yet - OpenAlgo creates it when needed" ;;
            UNKNOWN) say "  ⚠ $(basename "$path"): could not check ($detail) - left alone" "$YELLOW" ;;
            DAMAGED) say "  ✗ $(basename "$path"): DAMAGED ($detail)" "$RED"; damaged+=("$path") ;;
        esac
    done < <(check_dbs "$py" "$dir")

    if [ ${#damaged[@]} -gt 0 ]; then
        systemctl stop "$svc" 2>/dev/null
        local qdir="$dir/db/damaged-$TS" backup f copy
        mkdir -p "$qdir"
        backup=$(ls -dt /tmp/openalgo_backup_"${inst}"_* 2>/dev/null | head -1)
        for path in "${damaged[@]}"; do
            for f in "$path" "$path-wal" "$path-shm" "$path-journal"; do
                [ -e "$f" ] && mv "$f" "$qdir/"
            done
            copy="$backup/db/$(basename "$path")"
            if [ -n "$backup" ] && [ -s "$copy" ] && [ "$(check_dbs "$py" "$copy" | cut -f1)" = "OK" ]; then
                cp "$copy" "$path"
                migrate=1
                FIXED+=("$inst: $(basename "$path") was damaged - restored the healthy copy from the pre-update backup")
            else
                FIXED+=("$inst: $(basename "$path") was damaged - moved to db/damaged-$TS/, OpenAlgo recreates it empty")
            fi
        done
        restart=1
    fi
    find "$dir/db" -maxdepth 1 -type d -name 'damaged-*' -mtime +7 -exec rm -rf {} + 2>/dev/null

    # 2. Ownership
    local wrong
    wrong=$(find "$dir/db" ! -user www-data 2>/dev/null | wc -l)
    if [ "$wrong" -gt 0 ]; then
        chown -R www-data:www-data "$dir/db"
        say "  ✓ Gave $wrong db/ file(s) back to www-data" "$GREEN"
        FIXED+=("$inst: $wrong database file(s) were not owned by www-data")
        restart=1
    fi

    if [ "$migrate" -eq 1 ] && [ -f "$dir/upgrade/migrate_all.py" ]; then
        say "  Running migrations on the restored database(s)..." "$BLUE"
        sudo -u www-data env HOME="$dir/tmp" bash -c "cd '$dir' && '$py' upgrade/migrate_all.py" >/dev/null 2>&1 \
            || say "  ⚠ Migrations reported issues" "$YELLOW"
    fi

    # 3. Service
    if ! systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        systemctl enable --quiet "$svc" 2>/dev/null && FIXED+=("$inst: service was not enabled at boot")
    fi
    if ! systemctl is-active --quiet "$svc"; then
        restart=1
        FIXED+=("$inst: service was not running")
    fi
    [ "$restart" -eq 1 ] && { systemctl restart "$svc"; sleep 20; }

    local out attempt
    for attempt in 1 2; do
        out=$(bash "$SCRIPT_DIR/oa-health-check.sh" "$inst" 2>&1)
        if [ $? -ne 2 ]; then
            say "  ✓ Service running and serving requests" "$GREEN"
            return 0
        fi
        if [ "$attempt" -eq 1 ]; then
            say "  ✗ Not serving requests - restarting" "$YELLOW"
            systemctl restart "$svc"; sleep 20
            FIXED+=("$inst: service was not serving requests - restarted")
        fi
    done
    say "  ✗ $inst is still broken:" "$RED"
    printf '%s\n' "$out" | grep -E '✗|CRITICAL' | head -5 | sed 's/^/    /'
    journalctl -u "$svc" -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
    BROKEN+=("$inst ($svc) - see: journalctl -u $svc -n 100")
    return 2
}

self_test() {
    local t fails=0 got
    t=$(mktemp -d); trap 'rm -rf "$t"' RETURN
    mkdir -p "$t/db"
    python3 - "$t/db" <<'PY'
import sqlite3, sys
d = sys.argv[1]
for name in ("good.db", "corrupt.db"):
    c = sqlite3.connect(f"{d}/{name}")
    c.execute("CREATE TABLE t (x TEXT)")
    c.executemany("INSERT INTO t VALUES (?)", [("x" * 500,)] * 200)
    c.execute("CREATE INDEX i ON t(x)")
    c.commit(); c.close()
with open(f"{d}/corrupt.db", "r+b") as f:   # trash pages after the header
    f.seek(4096 * 3); f.write(b"\xde\xad\xbe\xef" * 2048)
open(f"{d}/garbage.db", "wb").write(b"this is not a database" * 300)
open(f"{d}/empty.db", "wb").close()
PY
    printf "DATABASE_URL = 'sqlite:///db/good.db'\nLOGS_DATABASE_URL = 'sqlite:///db/never.db'\nREDIS_URL = 'redis://x'\n" > "$t/.env"
    got=$(check_dbs python3 "$t")
    expect() {
        if printf '%s\n' "$got" | grep -q "^$2	$t/db/$1	"; then say "  ✓ $1 -> $2" "$GREEN"
        else say "  ✗ $1: want $2, got: $(printf '%s\n' "$got" | grep "/$1	")" "$RED"; fails=$((fails + 1)); fi
    }
    expect good.db OK
    expect corrupt.db DAMAGED
    expect garbage.db DAMAGED
    expect empty.db DAMAGED
    expect never.db MISSING
    # A database another process holds a write lock on is busy, not damaged.
    python3 - "$t/db/good.db" > "$t/held" 2>&1 <<'PY' &
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1], isolation_level=None)
c.execute("BEGIN EXCLUSIVE"); print("held", flush=True); time.sleep(30)
PY
    local holder=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q held "$t/held" 2>/dev/null && break; sleep 0.3; done
    got=$(sed 's/timeout=10/timeout=1/' <<< "$CHECKER" | python3 - "$t/db/good.db")
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    if [ "$(cut -f1 <<< "$got")" = "INUSE" ]; then say "  ✓ locked database -> INUSE (left alone)" "$GREEN"
    else say "  ✗ locked database: want INUSE, got: $got" "$RED"; fails=$((fails + 1)); fi
    [ "$fails" -eq 0 ] && { say "Self-test passed" "$GREEN"; return 0; }
    say "Self-test failed: $fails check(s)" "$RED"; return 1
}

case "${1:-all}" in
    --self-test) self_test; exit $? ;;
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
esac
[ "$EUID" -eq 0 ] || { say "Run as root (sudo)." "$RED"; exit 1; }

target="${1:-all}"
dirs=()
if [ "$target" = all ]; then
    for d in "$BASE_DIR"/openalgo[0-9]*; do [ -d "$d" ] && dirs+=("$d"); done
elif [ -d "$BASE_DIR/$target" ]; then
    dirs=("$BASE_DIR/$target")
else
    say "No such instance: $target" "$RED"; exit 2
fi

for d in "${dirs[@]}"; do repair_instance "$d"; done

if [ ${#FIXED[@]} -gt 0 ] || [ ${#BROKEN[@]} -gt 0 ]; then
    msg="🛠 $(hostname): instance check"$'\n'
    [ ${#FIXED[@]} -gt 0 ] && msg+="Fixed:"$'\n'"$(printf -- '- %s\n' "${FIXED[@]}")"$'\n'
    [ ${#BROKEN[@]} -gt 0 ] && msg+="🚨 STILL BROKEN:"$'\n'"$(printf -- '- %s\n' "${BROKEN[@]}")"
    say "\n$msg" "$([ ${#BROKEN[@]} -gt 0 ] && echo "$RED" || echo "$YELLOW")"
    telegram_send "$msg"
fi
[ ${#BROKEN[@]} -gt 0 ] && exit 2
[ ${#FIXED[@]} -gt 0 ] && exit 1
say "\n✓ All instances healthy" "$GREEN"
exit 0
