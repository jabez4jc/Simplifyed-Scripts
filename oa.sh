#!/bin/bash
# oa - one command for a Simplifyed OpenAlgo server.
#
#   oa install [--no-branding] [--swap GB]   first instance(s) + swap + admin dashboard
#   oa add [--no-branding]                   add more instances
#   oa update [INSTANCE] [--main]            update scripts, then instances to the newest
#                                            OpenAlgo release (--main: tip of main)
#   oa update-scripts                        only the scripts + dashboard; no instance
#                                            is touched (safe during market hours)
#   oa auto-update enable INSTANCE|all [--sundays]   install releases automatically, 03:30 IST
#   oa auto-update disable INSTANCE|all | status | telegram
#   oa status [INSTANCE]                     health check (default: all)
#   oa repair [INSTANCE]                     check DBs + services, fix what is broken
#   oa restart [INSTANCE|all]                restart instances
#   oa rollback BACKUP_DIR INSTANCE          undo an update
#   oa remove [INSTANCE] [--yes]             delete an instance (full backup first)
#   oa backup ...  | oa brand ...  | oa swap [GB]
#   oa daily-restart                         opt-in 8 AM IST restart (not for crypto)
#   oa admin                                 admin dashboard menu
#
# Each command runs the matching oa-*.sh script in this repo; those still work
# on their own (Fleet Manager and the dashboard call them directly).

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
case "${1:-help}" in help|-h|--help) ;; *)
    [ "$EUID" -eq 0 ] || exec sudo bash "$(readlink -f "${BASH_SOURCE[0]}")" "$@" ;;
esac

run() { local s="$1"; shift; bash "$SCRIPT_DIR/$s" "$@"; }

# Pull the latest scripts, then carry on with them.
self_update() {
    [ -z "${OA_NO_SELF_UPDATE:-}" ] || { refresh_dashboard; return 0; }
    git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1 || return 0
    local before; before=$(git -C "$SCRIPT_DIR" rev-parse HEAD)
    timeout 60 git -C "$SCRIPT_DIR" pull -q --ff-only || echo "⚠ Could not update the scripts repo; using the current copy"
    if [ "$(git -C "$SCRIPT_DIR" rev-parse HEAD)" != "$before" ]; then
        OA_NO_SELF_UPDATE=1 exec bash "$SCRIPT_DIR/oa.sh" "$@"
    fi
    refresh_dashboard
}

# api-manager installs the dashboard as a COPY in /usr/local/bin, so a scripts
# update does not reach it by itself.
refresh_dashboard() {
    local live=/usr/local/bin/openalgo-restart-api.py
    [ -f "$live" ] && ! cmp -s "$SCRIPT_DIR/openalgo-restart-api.py" "$live" || return 0
    cp "$SCRIPT_DIR/openalgo-restart-api.py" "$live"
    systemctl restart openalgo-restart-api && echo "✓ Admin dashboard updated"
}

cmd="${1:-help}"; shift 2>/dev/null
# Every command first picks up the latest scripts, so a fix pushed to GitHub
# reaches the server the next time any `oa` command runs.
case "$cmd" in help|-h|--help) ;; *) self_update "$cmd" "$@" ;; esac
case "$cmd" in
    install|add)
        BRANDING=y; SWAP_GB=4
        while [ $# -gt 0 ]; do
            case "$1" in
                --no-branding) BRANDING=n; shift ;;
                --swap) SWAP_GB="$2"; shift 2 ;;
                *) echo "Unknown option: $1"; exit 1 ;;
            esac
        done
        # No package-manager dialogs (Ubuntu's needrestart screen) mid-install
        export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
        if [ "$cmd" = install ] && ! swapon --show --noheadings 2>/dev/null | grep -q .; then
            echo y | run oa-configure-swap.sh "$SWAP_GB" || exit 1
        fi
        OA_DEFAULTS=1 BRANDING="$BRANDING" run multi-install.sh || exit 1
        # First time: ask for the dashboard login and domain, then Telegram
        if [ ! -f /etc/openalgo/admin-auth.json ]; then
            OA_ASK_ADMIN=1 run api-manager.sh setup
            # Optional (blank skips); a rejected token or chat ID gets two more tries
            if [ -z "$(. /etc/simplifyed/auto-update.conf 2>/dev/null; echo "${TELEGRAM_BOT_TOKEN:-}")" ]; then
                echo
                echo "Telegram notices: new releases, update results, repairs and failures."
                for _ in 1 2 3; do
                    run oa-auto-update.sh telegram; [ $? -eq 1 ] || break
                done
            fi
        elif ! systemctl is-active --quiet openalgo-restart-api; then
            run api-manager.sh setup
        fi
        cat <<'EOF'

Done. Optional next steps:
  oa auto-update enable all              install new OpenAlgo releases at 03:30 IST
  oa auto-update enable openalgoN --sundays   (crypto instances: Sundays only)
  oa auto-update telegram                release notices and results on Telegram
  oa daily-restart                       8 AM IST daily restart (not for crypto instances)
  oa admin                               change dashboard domain or admin password
EOF
        ;;
    update)
        target="update-all"; main=0
        for a in "$@"; do
            case "$a" in --main) main=1 ;; *) target="$a" ;; esac
        done
        if [ "$main" -eq 1 ]; then
            run oa-update.sh "$target"
        else
            tag=$(run oa-auto-update.sh latest-tag) || { echo "Could not find the latest OpenAlgo release"; exit 1; }
            echo "Updating to OpenAlgo release $tag"
            OA_UPDATE_TAG="$tag" run oa-update.sh "$target"
        fi
        rc=$?
        # Install or refresh the admin dashboard, its service and timers (safe
        # to repeat: keeps the admin login and a closed port 8888)
        run api-manager.sh setup
        exit $rc
        ;;
    update-scripts)
        # The pull and dashboard refresh already ran above (every command does);
        # this also re-applies the dashboard/timer setup. Instances untouched.
        echo "Scripts at $(git -C "$SCRIPT_DIR" log -1 --format='%h (%cd)' --date=format:'%d %b %H:%M')"
        run api-manager.sh setup
        ;;
    auto-update)   run oa-auto-update.sh "$@" ;;
    status)        run oa-health-check.sh "${@:-all}" ;;
    repair)        run oa-repair.sh "${@:-all}" ;;
    restart)       run oa-restart.sh "$@" ;;
    rollback)      run oa-update.sh rollback "$@" ;;
    backup)        run oa-backup.sh "$@" ;;
    remove)        run oa-uninstaller.sh "$@" ;;
    brand)         run oa-apply-branding.sh "$@" ;;
    swap)          run oa-configure-swap.sh "$@" ;;
    daily-restart) run setup-daily-restart.sh "$@" ;;
    admin)         run api-manager.sh "$@" ;;
    help|-h|--help) sed -n '2,18p' "$(readlink -f "${BASH_SOURCE[0]}")" | sed 's/^# \{0,1\}//' ;;
    *) echo "Unknown command: $cmd"; echo "Run: oa help"; exit 1 ;;
esac
