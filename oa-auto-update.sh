#!/bin/bash
# OpenAlgo Utility - install new OpenAlgo releases automatically
#
# Follows GitHub Releases of OpenAlgo (not every commit on main). A release is
# installed only once it has been public for SOAK_HOURS (default 72), so the
# quick fix releases that often follow a big one get picked up instead.
#
# Opt-in per instance, never by default (crypto instances trade 24/7):
#   daily    every day at 03:30 IST (equity/F&O/MCX are closed)
#   sunday   Sundays at 03:30 IST only (crypto: no trades at that time)
#
# Each run: updates this scripts repo, announces a newly published release on
# Telegram (with the date it will be installed), then updates eligible
# instances one at a time through oa-update.sh. A failed update is rolled back
# automatically (code, dependencies, .env, databases) and the rollout stops, so
# one bad release cannot take down every instance on the server.
#
# Usage:
#   oa-auto-update.sh enable <instance|all> [--sundays]
#   oa-auto-update.sh disable <instance|all>
#   oa-auto-update.sh status
#   oa-auto-update.sh telegram              # set bot token + chat id, send a test
#   oa-auto-update.sh run [--dry-run] [--force]   # what the 03:30 timer runs
#   oa-auto-update.sh latest-tag [--soak HOURS]   # newest eligible release tag
#   oa-auto-update.sh --self-test

set -uo pipefail

BASE_DIR="/var/python/openalgo-flask"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONF_FILE="/etc/simplifyed/auto-update.conf"
STATE_FILE="/var/lib/simplifyed/announced-release"
LOG_FILE="/var/log/oa-auto-update.log"
MARKER=".simplifyed-autoupdate"   # untracked, so git reset --hard keeps it
UNIT="oa-auto-update"

# Overridable in $CONF_FILE
SOAK_HOURS=72
OPENALGO_REPO="marketcalls/openalgo"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
# shellcheck disable=SC1090
[ -r "$CONF_FILE" ] && source "$CONF_FILE"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'

say() { echo -e "${2:-}$1${NC}"; }

# Reads the GitHub releases JSON on stdin. Prints KEY=VALUE lines:
#   ELIGIBLE_TAG      newest release at least SOAK hours old (what gets installed)
#   NEWEST_TAG/URL    newest release overall (what gets announced)
#   NEWEST_DAILY/NEWEST_SUNDAY  when NEWEST will be installed on each schedule
release_plan() {
    python3 -c '
import datetime as dt, json, re, sys
now = dt.datetime.fromtimestamp(int(sys.argv[1]), dt.timezone.utc)
soak = dt.timedelta(hours=int(sys.argv[2]))
IST = dt.timezone(dt.timedelta(hours=5, minutes=30))
rels = []
for r in json.load(sys.stdin):
    if r.get("draft") or r.get("prerelease") or not r.get("published_at"):
        continue
    if not re.fullmatch(r"[A-Za-z0-9._/-]+", r.get("tag_name", "")):
        continue
    r["_t"] = dt.datetime.fromisoformat(r["published_at"].replace("Z", "+00:00"))
    rels.append(r)
rels.sort(key=lambda r: r["_t"], reverse=True)

def next_slot(t, sunday):
    c = t.astimezone(IST).replace(hour=3, minute=30, second=0, microsecond=0)
    if c < t:
        c += dt.timedelta(days=1)
    while sunday and c.isoweekday() != 7:
        c += dt.timedelta(days=1)
    return c.strftime("%a %d %b %Y, 03:30 IST")

eligible = next((r for r in rels if r["_t"] + soak <= now), None)
for key, r in (("ELIGIBLE", eligible), ("NEWEST", rels[0] if rels else None)):
    if r:
        print(key + "_TAG=" + r["tag_name"])
        print(key + "_URL=" + r.get("html_url", ""))
if rels:
    due = rels[0]["_t"] + soak
    print(f"NEWEST_DAILY={next_slot(due, False)}")
    print(f"NEWEST_SUNDAY={next_slot(due, True)}")
' "$1" "$2"
}

# Sets ELIGIBLE_*/NEWEST_* from GitHub. Returns 1 when GitHub is unreachable.
load_plan() {
    local soak="$1" json
    ELIGIBLE_TAG=""; NEWEST_TAG=""; NEWEST_URL=""; NEWEST_DAILY=""; NEWEST_SUNDAY=""
    json=$(curl -fsSL -m 30 "https://api.github.com/repos/$OPENALGO_REPO/releases?per_page=30") || return 1
    while IFS='=' read -r key value; do
        case "$key" in
            ELIGIBLE_TAG|NEWEST_TAG|NEWEST_URL|NEWEST_DAILY|NEWEST_SUNDAY)
                printf -v "$key" '%s' "$value" ;;
        esac
    done < <(printf '%s' "$json" | release_plan "$(date +%s)" "$soak")
}

# Telegram. The token goes to curl on stdin (-K -), never on its command line,
# where any user on the server could read it from the process list.
telegram_send() {
    [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] || return 0
    local code
    code=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" \
        | curl -s -m 20 -K - -o /dev/null -w '%{http_code}' \
            --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
            --data-urlencode "text=$1" -d disable_web_page_preview=true)
    [ "$code" = "200" ]
}

instance_dirs() {
    local target="$1" dir
    if [ "$target" = "all" ]; then
        for dir in "$BASE_DIR"/openalgo[0-9]*; do [ -d "$dir" ] && echo "$dir"; done
    elif [ -d "$BASE_DIR/$target" ]; then
        echo "$BASE_DIR/$target"
    elif [ -d "$target" ]; then
        echo "$target"
    fi
}

instance_version() {
    grep -oE '^VERSION *= *"[^"]+"' "$1/utils/version.py" 2>/dev/null | cut -d'"' -f2
}

install_timer() {
    local calendar="*-*-* 03:30:00 Asia/Kolkata"
    # Timezone suffixes need systemd 245+. Older systemd: use server time,
    # which the installers set to IST.
    if ! systemd-analyze calendar "$calendar" >/dev/null 2>&1; then
        calendar="*-*-* 03:30:00"
        [ "$(timedatectl show -p Timezone --value 2>/dev/null)" = "Asia/Kolkata" ] \
            || say "⚠ Server timezone is not IST - the timer runs at 03:30 server time" "$YELLOW"
    fi
    cat > "/etc/systemd/system/$UNIT.service" <<EOF
[Unit]
Description=Install new OpenAlgo releases (opted-in instances)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $SCRIPT_DIR/oa-auto-update.sh run
TimeoutStartSec=4h
EOF
    # Persistent=false on purpose: a missed 03:30 run must NOT fire at boot,
    # which could be in the middle of the trading day.
    cat > "/etc/systemd/system/$UNIT.timer" <<EOF
[Unit]
Description=Check for new OpenAlgo releases at 03:30 IST

[Timer]
OnCalendar=$calendar
Persistent=false

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$UNIT.timer" >/dev/null 2>&1
}

cmd_enable() {
    local target="${1:-}" schedule="daily" dir n=0
    [ "${2:-}" = "--sundays" ] && schedule="sunday"
    [ -n "$target" ] || { say "Usage: $0 enable <instance|all> [--sundays]" "$RED"; return 1; }
    while IFS= read -r dir; do
        echo "$schedule" > "$dir/$MARKER"
        say "✓ $(basename "$dir"): auto-update $schedule at 03:30 IST" "$GREEN"
        n=$((n + 1))
    done < <(instance_dirs "$target")
    [ "$n" -gt 0 ] || { say "No instance found: $target" "$RED"; return 1; }
    install_timer
    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        say "Tip: get release notices and results on Telegram with: oa auto-update telegram" "$BLUE"
    fi
}

cmd_disable() {
    local target="${1:-}" dir
    [ -n "$target" ] || { say "Usage: $0 disable <instance|all>" "$RED"; return 1; }
    while IFS= read -r dir; do
        rm -f "$dir/$MARKER"
        say "✓ $(basename "$dir"): auto-update off" "$GREEN"
    done < <(instance_dirs "$target")
    if ! compgen -G "$BASE_DIR/openalgo[0-9]*/$MARKER" >/dev/null; then
        systemctl disable --now "$UNIT.timer" >/dev/null 2>&1
        say "No instance opted in any more - timer stopped" "$BLUE"
    fi
}

cmd_status() {
    local dir schedule
    say "Instances:" "$BLUE"
    while IFS= read -r dir; do
        schedule="off"
        [ -f "$dir/$MARKER" ] && schedule="$(cat "$dir/$MARKER")"
        printf '  %-12s %-10s %-8s %s\n' "$(basename "$dir")" "v$(instance_version "$dir")" "$schedule" \
            "$(grep -E '^DOMAIN *=' "$dir/.env" 2>/dev/null | cut -d= -f2- | tr -d "' ")"
    done < <(instance_dirs all)
    echo
    systemctl list-timers "$UNIT.timer" --no-pager 2>/dev/null | head -2
    echo
    if load_plan "$SOAK_HOURS"; then
        say "Newest release:   ${NEWEST_TAG:-none}  $NEWEST_URL"
        say "Will install:     ${ELIGIBLE_TAG:-none yet} (releases wait ${SOAK_HOURS}h)"
    else
        say "⚠ Could not reach GitHub" "$YELLOW"
    fi
    say "Telegram:         $([ -n "$TELEGRAM_BOT_TOKEN" ] && echo "on (chat $TELEGRAM_CHAT_ID)" || echo off)"
    say "Log:              $LOG_FILE"
}

save_conf() {
    mkdir -p "$(dirname "$CONF_FILE")"
    ( umask 077
      { printf 'TELEGRAM_BOT_TOKEN=%q\n' "$TELEGRAM_BOT_TOKEN"
        printf 'TELEGRAM_CHAT_ID=%q\n' "$TELEGRAM_CHAT_ID"
        printf 'SOAK_HOURS=%q\n' "$SOAK_HOURS"
        printf 'OPENALGO_REPO=%q\n' "$OPENALGO_REPO"; } > "$CONF_FILE" )
}

cmd_telegram() {
    local token chat
    say "Create a bot with @BotFather in Telegram and paste its token." "$BLUE"
    read -rsp "Bot token (hidden; blank to skip): " token; echo
    # 2 = skipped (oa install stops asking), 1 = rejected (it asks again)
    [ -n "$token" ] || { say "Skipped - set it up any time with: sudo oa auto-update telegram" "$YELLOW"; return 2; }
    # Token via curl's config on stdin, never argv. Prints "@bot", a chat ID,
    # or "ERR <Telegram's own reason>" - so a wrong token, a webhook or no
    # messages are told apart instead of all reading "no message found".
    tg() {
        printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$token" "$1" | curl -s -m 20 -K - \
            | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(print("ERR no answer from api.telegram.org"))
if not d.get("ok"):
    sys.exit(print("ERR " + d.get("description", "unknown error")))
r = d["result"]
if isinstance(r, dict):
    sys.exit(print("@" + r.get("username", "?")))
for u in reversed(r):  # newest first; /start, edits and joins carry the chat too
    for k in ("message", "edited_message", "channel_post", "my_chat_member"):
        if k in u:
            sys.exit(print(u[k]["chat"]["id"]))'
    }
    local bot
    bot=$(tg getMe)
    case "$bot" in
        @*) say "Bot: $bot" "$GREEN" ;;
        *)  say "❌ Telegram did not accept the token: ${bot#ERR }" "$RED"
            say "   Copy it again from @BotFather (/mybots → the bot → API Token)." "$YELLOW"
            return 1 ;;
    esac
    read -rp "Chat ID (leave blank to detect it - send any message to the bot first): " chat
    if [ -z "$chat" ]; then
        chat=$(tg getUpdates)
        case "$chat" in
            ERR*webhook*)
                say "❌ $bot has a webhook set, so its messages go to another app and cannot be read here." "$RED"
                say "   Enter the chat ID by hand (message @userinfobot to get yours), or use a separate bot." "$YELLOW"
                return 1 ;;
            ERR*) say "❌ ${chat#ERR }" "$RED"; return 1 ;;
            "")
                say "❌ No message found for $bot. Send it a message, then run this again." "$RED"
                say "   Still nothing? Something else may be reading this bot's messages - enter the" "$YELLOW"
                say "   chat ID by hand instead (message @userinfobot to get yours)." "$YELLOW"
                return 1 ;;
        esac
        say "Detected chat ID: $chat" "$GREEN"
    fi
    TELEGRAM_BOT_TOKEN="$token"; TELEGRAM_CHAT_ID="$chat"
    if telegram_send "✅ $(hostname): OpenAlgo auto-update notifications are on."; then
        save_conf
        say "✓ Test message sent. Saved to $CONF_FILE" "$GREEN"
    else
        say "❌ Telegram rejected the token or chat ID. Nothing saved." "$RED"
        return 1
    fi
}

cmd_run() {
    local dry=0 force=0 arg
    for arg in "$@"; do
        case "$arg" in --dry-run) dry=1 ;; --force) force=1 ;; esac
    done

    exec 9>/run/oa-auto-update.lock
    flock -n 9 || { say "Another auto-update is running." "$YELLOW"; return 0; }

    # Restarts are only safe while markets are closed. The timer fires at 03:30;
    # this guards against someone running it by hand mid-session.
    local hhmm; hhmm=$(TZ=Asia/Kolkata date +%H%M)
    if [ "$dry" -eq 0 ] && [ "$force" -eq 0 ] && { [ "$hhmm" -lt 0300 ] || [ "$hhmm" -ge 0600 ]; }; then
        say "Refusing to restart instances at $(TZ=Asia/Kolkata date +%H:%M) IST (allowed 03:00-06:00). Use --force to override." "$RED"
        return 3
    fi

    # Update this scripts repo first, then continue with the new copy.
    if [ -z "${OA_NO_SELF_UPDATE:-}" ] && [ "$dry" -eq 0 ] && git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        local before; before=$(git -C "$SCRIPT_DIR" rev-parse HEAD)
        git -C "$SCRIPT_DIR" pull -q --ff-only 2>&1
        if [ "$(git -C "$SCRIPT_DIR" rev-parse HEAD)" != "$before" ]; then
            say "Scripts updated - continuing with the new version" "$BLUE"
            exec 9>&-
            OA_NO_SELF_UPDATE=1 exec bash "$SCRIPT_DIR/oa-auto-update.sh" run "$@"
        fi
    fi

    # api-manager installs the dashboard as a copy; keep it in step with the repo.
    local live=/usr/local/bin/openalgo-restart-api.py
    if [ "$dry" -eq 0 ] && [ -f "$live" ] && ! cmp -s "$SCRIPT_DIR/openalgo-restart-api.py" "$live"; then
        cp "$SCRIPT_DIR/openalgo-restart-api.py" "$live" && systemctl restart openalgo-restart-api
        say "✓ Admin dashboard updated" "$GREEN"
    fi

    say "=== $(TZ=Asia/Kolkata date '+%F %T') IST ===" "$BLUE"
    if ! load_plan "$SOAK_HOURS"; then
        say "❌ Could not reach GitHub releases - nothing done" "$RED"
        return 1
    fi

    # Announce a release once, as soon as it is seen, so its notes can be read
    # (behaviour changes!) before it is installed.
    if [ -n "$NEWEST_TAG" ] && [ "$dry" -eq 0 ] && [ "$(cat "$STATE_FILE" 2>/dev/null)" != "$NEWEST_TAG" ]; then
        if telegram_send "📦 $(hostname): new OpenAlgo release $NEWEST_TAG
Daily instances install it: $NEWEST_DAILY
Sunday instances install it: $NEWEST_SUNDAY
Please read the release notes for behaviour changes:
$NEWEST_URL"; then
            mkdir -p "$(dirname "$STATE_FILE")"
            echo "$NEWEST_TAG" > "$STATE_FILE"
        fi
    fi

    if [ -z "$ELIGIBLE_TAG" ]; then
        say "No release older than ${SOAK_HOURS}h yet."
        return 0
    fi
    say "Release to install: $ELIGIBLE_TAG"

    local sunday=0; [ "$(TZ=Asia/Kolkata date +%u)" = 7 ] && sunday=1
    local updated=() rolled_back=() broken=() dir inst schedule sha rc backup
    for dir in "$BASE_DIR"/openalgo[0-9]*; do
        [ -f "$dir/$MARKER" ] || continue
        inst=$(basename "$dir"); schedule=$(cat "$dir/$MARKER")
        if [ "$schedule" = "sunday" ] && [ "$sunday" -eq 0 ]; then
            say "· $inst: Sunday-only, skipped"; continue
        fi
        git config --global --add safe.directory "$dir" 2>/dev/null
        if ! git -C "$dir" fetch -q --force origin "refs/tags/$ELIGIBLE_TAG:refs/tags/$ELIGIBLE_TAG" 2>/dev/null \
            || ! sha=$(git -C "$dir" rev-parse --verify --quiet "refs/tags/$ELIGIBLE_TAG^{commit}"); then
            say "⚠ $inst: could not fetch $ELIGIBLE_TAG" "$YELLOW"; continue
        fi
        if git -C "$dir" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
            say "· $inst: already on $ELIGIBLE_TAG or newer (v$(instance_version "$dir"))"; continue
        fi
        if [ "$dry" -eq 1 ]; then
            say "→ $inst: would update v$(instance_version "$dir") to $ELIGIBLE_TAG" "$BLUE"; continue
        fi

        say "→ $inst: updating to $ELIGIBLE_TAG" "$BLUE"
        local prev_backup; prev_backup=$(ls -dt /tmp/openalgo_backup_"${inst}"_* 2>/dev/null | head -1)
        OA_UPDATE_TAG="$ELIGIBLE_TAG" bash "$SCRIPT_DIR/oa-update.sh" "$inst"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            updated+=("$inst v$(instance_version "$dir")")
            continue
        fi

        # The update failed: put back the code, dependencies, .env and databases
        # from the pre-update backup, and stop - the next instances keep running
        # their current version until someone has looked at this.
        # Only this run's backup: an older one would restore stale databases.
        backup=$(ls -dt /tmp/openalgo_backup_"${inst}"_* 2>/dev/null | head -1)
        if [ -z "$backup" ] || [ "$backup" = "$prev_backup" ]; then
            rolled_back+=("$inst (failed before changing anything)")
        elif bash "$SCRIPT_DIR/oa-update.sh" rollback "$backup" "$inst"; then
            rolled_back+=("$inst")
        else
            broken+=("$inst")
        fi
        break
    done

    [ "$dry" -eq 1 ] && return 0
    local msg=""
    [ ${#updated[@]} -gt 0 ] && msg+="✅ Updated to $ELIGIBLE_TAG: ${updated[*]}"$'\n'
    [ ${#rolled_back[@]} -gt 0 ] && msg+="⚠️ Update failed and was rolled back: ${rolled_back[*]}. Remaining instances were not updated."$'\n'
    [ ${#broken[@]} -gt 0 ] && msg+="🚨 Update AND rollback failed: ${broken[*]} - needs attention now. Log: $LOG_FILE"$'\n'
    if [ -n "$msg" ]; then
        say "$msg"
        telegram_send "🖥 $(hostname)"$'\n'"$msg" || say "⚠ Telegram notification failed" "$YELLOW"
    fi
    [ ${#rolled_back[@]} -eq 0 ] && [ ${#broken[@]} -eq 0 ]
}

self_test() {
    local fails=0 out
    check() { if [ "$2" = "$3" ]; then say "  ✓ $1" "$GREEN"; else say "  ✗ $1: got '$2', want '$3'" "$RED"; fails=$((fails + 1)); fi; }
    get() { printf '%s\n' "$out" | grep "^$1=" | cut -d= -f2-; }

    # now = Fri 2026-10-16 22:00 UTC (Sat 03:30 IST)
    local now=1792188000
    out=$(release_plan "$now" 72 <<'EOF'
[{"tag_name":"newest","published_at":"2026-10-15T12:04:57Z","html_url":"u1"},
 {"tag_name":"beta","published_at":"2026-10-14T00:00:00Z","prerelease":true},
 {"tag_name":"draft","published_at":"2026-10-13T00:00:00Z","draft":true},
 {"tag_name":"soaked","published_at":"2026-10-08T06:17:05Z","html_url":"u2"},
 {"tag_name":"bad tag;rm","published_at":"2026-10-01T00:00:00Z"}]
EOF
)
    check "newest release found"                  "$(get NEWEST_TAG)" "newest"
    check "release younger than 72h not eligible" "$(get ELIGIBLE_TAG)" "soaked"
    # newest + 72h = Sun 18 Oct 17:34 IST -> daily slot Mon 19 Oct, Sunday slot 25 Oct
    check "daily install slot"                    "$(get NEWEST_DAILY)" "Mon 19 Oct 2026, 03:30 IST"
    check "Sunday install slot"                   "$(get NEWEST_SUNDAY)" "Sun 25 Oct 2026, 03:30 IST"
    out=$(release_plan "$now" 0 <<< '[{"tag_name":"x","published_at":"2026-10-15T12:04:57Z"}]')
    check "no soak: newest eligible"              "$(get ELIGIBLE_TAG)" "x"
    out=$(release_plan "$now" 72 <<< '[{"tag_name":"bad tag;rm","published_at":"2026-01-01T00:00:00Z"}]')
    check "unsafe tag names ignored"              "$(get ELIGIBLE_TAG)" ""

    [ "$fails" -eq 0 ] && { say "Self-test passed" "$GREEN"; return 0; }
    say "Self-test failed: $fails check(s)" "$RED"; return 1
}

case "${1:-}" in
    --self-test) self_test; exit $? ;;
    latest-tag)
        soak=0; [ "${2:-}" = "--soak" ] && soak="${3:-0}"
        load_plan "$soak" || { echo "Could not reach GitHub" >&2; exit 1; }
        [ -n "$ELIGIBLE_TAG" ] || exit 1
        echo "$ELIGIBLE_TAG"; exit 0 ;;
    -h|--help|"") sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
esac

[ "$EUID" -eq 0 ] || { say "Run as root (sudo)." "$RED"; exit 1; }
cmd="$1"; shift
case "$cmd" in
    enable)   cmd_enable "$@" ;;
    disable)  cmd_disable "$@" ;;
    status)   cmd_status ;;
    telegram) cmd_telegram ;;
    run)
        # A self-updated re-run is already inside the first run's tee
        [ -n "${OA_LOGGED:-}" ] && { cmd_run "$@"; exit $?; }
        export OA_LOGGED=1
        mkdir -p "$(dirname "$LOG_FILE")"
        cmd_run "$@" 2>&1 | tee -a "$LOG_FILE"; exit "${PIPESTATUS[0]}" ;;
    *)        say "Unknown command: $cmd (see --help)" "$RED"; exit 1 ;;
esac
