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

# Prints the *_DATABASE_URL keys it reset (env file, sample file).
ENVFIX='
import re, sys
env, sample = sys.argv[1], sys.argv[2]
line = re.compile(r"^([A-Z_]+_DATABASE_URL|DATABASE_URL)\s*=\s*[\x27\"]?([^\x27\"#\s]*).*$", re.M)
text = open(env).read()
vals = {k: v for k, v in line.findall(text)}
defaults = {k: v for k, v in line.findall(open(sample).read())}
main = vals.get("DATABASE_URL")
fixed = []
def sub(m):
    k = m.group(1)
    if main and k != "DATABASE_URL" and m.group(2) == main and defaults.get(k) not in (None, "", main):
        fixed.append(k)
        return "%s = \x27%s\x27" % (k, defaults[k])
    return m.group(0)
new = line.sub(sub, text)
if fixed:
    open(env, "w").write(new)  # rewrite in place: keeps owner and 600
    print(", ".join(fixed))
'

# Prints db/*.db|*.duckdb files nothing points at (instance dir). In use = every
# DB key in .env, plus OpenAlgo's built-in default for each one .env leaves out.
ORPHANS='
import glob, os, re, sys
inst = sys.argv[1]
defaults = {"DATABASE_URL": "db/openalgo.db", "LATENCY_DATABASE_URL": "db/latency.db",
            "LOGS_DATABASE_URL": "db/logs.db", "HEALTH_DATABASE_URL": "db/health.db",
            "SANDBOX_DATABASE_URL": "db/sandbox.db", "HISTORIFY_DATABASE_PATH": "db/historify.duckdb",
            "HISTORIFY_DATABASE_URL": "db/historify.duckdb"}
env = {}
for line in open(os.path.join(inst, ".env")):
    m = re.match(r"\s*([A-Z_]+)\s*=\s*[\x27\"]?([^\x27\"#\s]*)", line)
    if m:
        env[m.group(1)] = m.group(2)
if not env.get("DATABASE_URL"):
    sys.exit(0)  # cannot tell what is in use - delete nothing
used = {env.get(k) or d for k, d in defaults.items()}
used |= {v for k, v in env.items() if re.search(r"DATABASE|DB_(URL|PATH)|DUCKDB", k)}
def resolve(v):
    if v.startswith("sqlite:///"):
        v = v[len("sqlite:///"):]
    return os.path.realpath(v if os.path.isabs(v) else os.path.join(inst, v))
used = {resolve(v) for v in used if v}
for p in sorted(glob.glob(os.path.join(inst, "db", "*.db")) + glob.glob(os.path.join(inst, "db", "*.duckdb"))):
    if os.path.realpath(p) not in used:
        print(p)
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

# Names this server in Telegram notices (one bot serves many servers; the VPS
# hostname, e.g. 129-121-168-158.bluehost.com, says nothing): the admin
# dashboard's domain, else the first instance's domain, else the hostname
server_name() {
    local d
    d=$(systemctl cat openalgo-restart-api 2>/dev/null | sed -n 's/^Environment=MANAGER_DOMAIN=//p' | tail -1)
    [ -n "$d" ] || d=$(grep -hE '^DOMAIN *=' "$BASE_DIR"/openalgo[0-9]*/.env 2>/dev/null | head -1 | cut -d= -f2- | tr -d "' \"\r")
    echo "${d:-$(hostname)}"
}

telegram_send() {
    [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] || return 0
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" \
        | curl -s -m 20 -K - -o /dev/null --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$1"
}

FIXED=(); BROKEN=()

# Recreate a venv www-data cannot run, on the system Python (same steps as
# multi-install.sh). A UV_PYTHON=3.12 set by a VPS image made uv download a
# Python into root's 700 home: "bad interpreter: Permission denied".
rebuild_venv() {
    local dir="$1" pins
    pins=$(grep -oE '^(gunicorn|eventlet)[=<>~!][^[:space:]#]*' "$dir/requirements-nginx.txt" 2>/dev/null | tr '\n' ' ')
    [ -n "$pins" ] || pins="gunicorn>=25.0,<26 eventlet==0.41.2"
    rm -rf "$dir/venv"
    # shellcheck disable=SC2086  # pins: one word per requirement, no spaces inside
    (cd "$dir" && export UV_PYTHON=/usr/bin/python3 && uv venv -q venv && UV_PROJECT_ENVIRONMENT="$dir/venv" uv sync -q \
        && uv pip install -q --python venv/bin/python $pins) && chown -R www-data:www-data "$dir/venv"
}

repair_instance() {
    local dir="$1" inst svc py restart=0 migrate=0 status path detail
    inst=$(basename "$dir"); svc=$(service_name_of "$dir")
    say "\n── $inst ($svc)" "$BLUE"

    # 0. venv: the service runs as www-data, so www-data must be able to start
    # its Python (see rebuild_venv)
    if [ -e "$dir/venv" ] && ! sudo -u www-data "$dir/venv/bin/python" -c pass >/dev/null 2>&1; then
        say "  ✗ www-data cannot run venv/bin/python ($(readlink -f "$dir/venv/bin/python")) - rebuilding the venv..." "$YELLOW"
        if rebuild_venv "$dir" && sudo -u www-data "$dir/venv/bin/python" -c pass >/dev/null 2>&1; then
            say "  ✓ venv rebuilt ($(readlink -f "$dir/venv/bin/python"))" "$GREEN"
            FIXED+=("$inst: www-data could not run the venv's Python - venv rebuilt")
            restart=1
        else
            say "  ✗ venv rebuild failed" "$RED"
        fi
    fi
    py="$dir/venv/bin/python"; [ -x "$py" ] || py=python3

    # 0. .env: an old installer sed (unanchored "DATABASE_URL = ...") pointed
    # HEALTH/SANDBOX/HISTORIFY_DATABASE_URL at the main DB. Updates carry the
    # values over, so put them back to the .sample.env defaults here.
    local envfix
    if [ -f "$dir/.sample.env" ] && envfix=$(python3 -c "$ENVFIX" "$dir/.env" "$dir/.sample.env") && [ -n "$envfix" ]; then
        say "  ✓ .env: $envfix no longer share the main database" "$GREEN"
        FIXED+=("$inst: $envfix pointed at the main database - reset to OpenAlgo's defaults")
        restart=1
    fi

    # 0b. Orphaned databases (e.g. a stray openalgo.db next to openalgo<N>.db):
    # nothing reads them, so delete them - unless some process has one open.
    local orphan f
    while IFS= read -r orphan; do
        [ -n "$orphan" ] || continue
        if find /proc/[0-9]*/fd -lname "$orphan" 2>/dev/null | grep -q .; then
            say "  · $(basename "$orphan"): not used by .env but open by a process - left alone"
            continue
        fi
        for f in "$orphan" "$orphan-wal" "$orphan-shm" "$orphan-journal" "$orphan.wal"; do rm -f "$f"; done
        say "  ✓ Deleted orphaned $(basename "$orphan") (nothing uses it)" "$GREEN"
        FIXED+=("$inst: deleted orphaned database $(basename "$orphan")")
    done < <([ -f "$dir/.env" ] && python3 -c "$ORPHANS" "$dir")

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

    # Judge only "is it up and answering" - not the full health check, whose
    # CRITICAL also covers server-wide things (a full disk) a restart can't fix.
    local attempt code
    for attempt in 1 2; do
        code=$(sudo -u www-data curl -s -m 10 -o /dev/null -w '%{http_code}' --unix-socket "$dir/openalgo.sock" http://localhost/ 2>/dev/null)
        if systemctl is-active --quiet "$svc" && [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
            say "  ✓ Service running and serving requests" "$GREEN"
            return 0
        fi
        if [ "$attempt" -eq 1 ]; then
            say "  ✗ Not serving requests - restarting" "$YELLOW"
            systemctl restart "$svc"; sleep 20
            FIXED+=("$inst: service was not serving requests - restarted")
        fi
    done
    say "  ✗ $inst is still broken (service $(systemctl is-active "$svc"), HTTP ${code:-none}):" "$RED"
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
    # .env with the old installer's shared-DB paths gets the defaults back.
    printf "DATABASE_URL = 'sqlite:///db/openalgo3.db'\nLOGS_DATABASE_URL = 'sqlite:///db/logs3.db'\nSANDBOX_DATABASE_URL = 'sqlite:///db/openalgo3.db'  # sandbox\nHISTORIFY_DATABASE_URL = 'sqlite:///db/openalgo3.db'\n" > "$t/bad.env"
    printf "DATABASE_URL = 'sqlite:///db/openalgo.db'\nLOGS_DATABASE_URL = 'sqlite:///db/logs.db'\nSANDBOX_DATABASE_URL = 'sqlite:///db/sandbox.db'\nHISTORIFY_DATABASE_URL = 'db/historify.duckdb'\n" > "$t/sample.env"
    got=$(python3 -c "$ENVFIX" "$t/bad.env" "$t/sample.env")
    if [ "$got" = "SANDBOX_DATABASE_URL, HISTORIFY_DATABASE_URL" ] \
        && grep -q "^SANDBOX_DATABASE_URL = 'sqlite:///db/sandbox.db'$" "$t/bad.env" \
        && grep -q "^HISTORIFY_DATABASE_URL = 'db/historify.duckdb'$" "$t/bad.env" \
        && grep -q "^DATABASE_URL = 'sqlite:///db/openalgo3.db'$" "$t/bad.env" \
        && grep -q "^LOGS_DATABASE_URL = 'sqlite:///db/logs3.db'$" "$t/bad.env" \
        && [ -z "$(python3 -c "$ENVFIX" "$t/bad.env" "$t/sample.env")" ]; then
        say "  ✓ .env shared-DB paths reset, others kept, second run no-op" "$GREEN"
    else say "  ✗ .env fix: got '$got'; $(cat "$t/bad.env")" "$RED"; fails=$((fails + 1)); fi
    # Orphans: stray openalgo.db goes; named, defaulted (sandbox/historify) and
    # .env-pointed files stay. Without DATABASE_URL nothing is reported.
    mkdir -p "$t/o/db"
    touch "$t"/o/db/{openalgo.db,openalgo2.db,logs2.db,sandbox.db,historify.duckdb,custom.db}
    printf "DATABASE_URL = 'sqlite:///db/openalgo2.db'\nLOGS_DATABASE_URL = 'sqlite:///db/logs2.db'\nMY_DB_PATH = 'db/custom.db'\n" > "$t/o/.env"
    got=$(python3 -c "$ORPHANS" "$t/o")
    if [ "$got" = "$t/o/db/openalgo.db" ]; then say "  ✓ orphan detection: only the stray openalgo.db" "$GREEN"
    else say "  ✗ orphans: got '$got'" "$RED"; fails=$((fails + 1)); fi
    printf "LOGS_DATABASE_URL = 'sqlite:///db/logs2.db'\n" > "$t/o/.env"
    if [ -n "$(python3 -c "$ORPHANS" "$t/o")" ]; then say "  ✗ orphans without DATABASE_URL must be empty" "$RED"; fails=$((fails + 1))
    else say "  ✓ no DATABASE_URL -> nothing deleted" "$GREEN"; fi
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

# Disk: a full disk breaks SQLite writes and updates. At 85%+ run the usual
# nightly cleanup now, and name what is still big if that isn't enough.
disk_pct() { df --output=pcent / | tail -1 | tr -dc '0-9'; }
pct=$(disk_pct)
if [ "${pct:-0}" -ge 85 ]; then
    say "\n── Disk ${pct}% full - cleaning up" "$YELLOW"
    bash "$SCRIPT_DIR/oa-clear-logs.sh" --yes --no-docker >/dev/null 2>&1
    find /var/backups/openalgo -maxdepth 1 -type f -mtime +14 -delete 2>/dev/null
    # Update backups made before they excluded Historify's DuckDB (GBs each)
    rm -f /tmp/openalgo_backup_*/db/*.duckdb* 2>/dev/null
    rm -rf /tmp/openalgo_backup_*/db/*/ 2>/dev/null
    after=$(disk_pct)
    say "  Disk ${pct}% → ${after}%" "$([ "$after" -lt 85 ] && echo "$GREEN" || echo "$RED")"
    FIXED+=("disk was ${pct}% full - logs, journal and old backups cleaned, now ${after}%")
    if [ "$after" -ge 85 ]; then
        say "  Still big:" "$RED"
        du -xh --max-depth=3 / 2>/dev/null | sort -rh | sed -n '2,9p' | sed 's/^/    /'
        # Not BROKEN: exit 2 makes oa-update roll back, and a rollback frees nothing
        FIXED+=("⚠ disk still ${after}% full - see the 'Still big' list from: sudo oa repair")
    fi
fi

if [ ${#FIXED[@]} -gt 0 ] || [ ${#BROKEN[@]} -gt 0 ]; then
    msg="🛠 $(server_name): instance check"$'\n'
    [ ${#FIXED[@]} -gt 0 ] && msg+="Fixed:"$'\n'"$(printf -- '- %s\n' "${FIXED[@]}")"$'\n'
    [ ${#BROKEN[@]} -gt 0 ] && msg+="🚨 STILL BROKEN:"$'\n'"$(printf -- '- %s\n' "${BROKEN[@]}")"
    say "\n$msg" "$([ ${#BROKEN[@]} -gt 0 ] && echo "$RED" || echo "$YELLOW")"
    telegram_send "$msg"
fi
[ ${#BROKEN[@]} -gt 0 ] && exit 2
[ ${#FIXED[@]} -gt 0 ] && exit 1
say "\n✓ All instances healthy" "$GREEN"
exit 0
