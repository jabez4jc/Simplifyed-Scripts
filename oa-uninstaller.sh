#!/bin/bash
# Remove an OpenAlgo instance: service, files, nginx site, certificate.
# A full backup (incl. .env and databases) is taken first; if it fails,
# nothing is deleted.
#
#   oa-uninstaller.sh                    menu
#   oa-uninstaller.sh INSTANCE [--yes]   one instance (--yes: no question;
#                                        used by the dashboard API)

# === CONFIG ===
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BACKUP_DIR="${OA_BACKUP_DIR:-/var/backups/openalgo}"
BASE_DIR="/var/python/openalgo-flask"
NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"

# === Functions ===

get_service_name() {
    local instance_dir="$1"
    local fallback_name="$2"
    local env_file="$instance_dir/.env"
    local domain=""

    if [ -f "$env_file" ]; then
        domain=$(grep -E "^DOMAIN *=" "$env_file" | head -1 | cut -d'=' -f2- | tr -d "' \"\r")
    fi

    if [ -n "$domain" ]; then
        echo "openalgo-${domain//./-}"
    elif [[ "$fallback_name" == openalgo* ]]; then
        echo "$fallback_name"
    else
        echo "openalgo$fallback_name"
    fi
}

remove_instance() {
    local DEPLOY_NAME="$1"
    local INSTANCE_DIR="$BASE_DIR/$DEPLOY_NAME"
    local ENV_FILE="$INSTANCE_DIR/.env"
    local SERVICE_NAME
    SERVICE_NAME=$(get_service_name "$INSTANCE_DIR" "$DEPLOY_NAME")
    local DOMAIN=""
    if [ -f "$ENV_FILE" ]; then
        DOMAIN=$(grep -E "^DOMAIN *=" "$ENV_FILE" | head -1 | cut -d'=' -f2- | tr -d "' \"\r")
    fi
    # Nginx configs are written as sites-available/<domain> (no extension) - see multi-install.sh
    local NGINX_CONF="$NGINX_AVAILABLE/$DOMAIN"
    local NGINX_LINK="$NGINX_ENABLED/$DOMAIN"
    local SOCKET_FILE="$INSTANCE_DIR/openalgo.sock"

    echo "🔧 Removing instance: $DEPLOY_NAME"

    echo "🛑 Stopping service: $SERVICE_NAME"
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null

    # Full backup first (stopped, so the databases are consistent): openalgo.db
    # holds the users, API keys and broker logins. No verified archive, no delete.
    echo "💾 Backing up $DEPLOY_NAME..."
    local started archive
    started=$(date +%s)
    bash "$SCRIPT_DIR/oa-backup.sh" single full "$DEPLOY_NAME" >/dev/null 2>&1
    archive=$(ls -t "$BACKUP_DIR/${DEPLOY_NAME}_full_"*.tar.gz 2>/dev/null | head -1)
    if [ -z "$archive" ] || [ "$(stat -c %Y "$archive")" -lt "$started" ] || ! gzip -t "$archive" 2>/dev/null; then
        echo "❌ Backup failed - $DEPLOY_NAME was NOT removed (service started again)"
        sudo systemctl start "$SERVICE_NAME" 2>/dev/null
        return 1
    fi
    echo "   $archive (restore: tar -xzf it into $BASE_DIR)"

    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null
    sudo rm -f "/etc/systemd/system/$SERVICE_NAME.service"

    echo "🧹 Cleaning instance log files..."
    for log_dir in "$INSTANCE_DIR/log" "$INSTANCE_DIR/logs"; do
        if [ -d "$log_dir" ]; then
            sudo find "$log_dir" -type f -delete 2>/dev/null || true
        fi
    done

    echo "🗑️ Deleting files and directories..."
    sudo rm -rf "$INSTANCE_DIR"
    sudo rm -f "$SOCKET_FILE"

    if [ -n "$DOMAIN" ]; then
        echo "🧹 Cleaning nginx config for domain: $DOMAIN"
        sudo rm -f "$NGINX_CONF" "$NGINX_LINK"
        sudo rm -f "$BASE_DIR/openalgo-${DOMAIN//./-}"   # the installer's domain-named symlink

        if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
            echo "🧯 Removing SSL certificate for $DOMAIN"
            sudo certbot delete --cert-name "$DOMAIN" --non-interactive
        fi
    else
        echo "⚠️  No DOMAIN found in .env — skipping nginx config and SSL cleanup"
    fi

    echo "✅ $DEPLOY_NAME removed"
}

# === Script Entry ===

echo "🔍 Looking for OpenAlgo instances..."
if [ ! -d "$BASE_DIR" ]; then
    echo "❌ No instances found in $BASE_DIR"
    exit 1
fi

mapfile -t INSTANCES < <(find "$BASE_DIR" -maxdepth 1 -type d -name "openalgo[0-9]*" -printf "%f\n" 2>/dev/null | sort)
if [ ${#INSTANCES[@]} -eq 0 ]; then
    echo "❌ No OpenAlgo instances installed."
    exit 1
fi

# Nginx reload, not restart: a restart drops every other instance's connections
reload_web() {
    echo "🔄 Reloading systemd and nginx..."
    sudo systemctl daemon-reload
    sudo nginx -t >/dev/null 2>&1 && sudo systemctl reload nginx
}

# === One named instance (no menu) ===
TARGET=""; YES=0
for a in "$@"; do
    case "$a" in --yes|-y) YES=1 ;; --instance) ;; *) TARGET="$a" ;; esac
done
if [ -n "$TARGET" ]; then
    printf '%s\n' "${INSTANCES[@]}" | grep -qxF -- "$TARGET" || { echo "❌ No such instance: $TARGET"; exit 1; }
    if [ "$YES" -ne 1 ]; then
        read -p "⚠️ Confirm removal of '$TARGET'? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "❌ Aborted."; exit 1; }
    fi
    remove_instance "$TARGET" || exit 1
    reload_web
    echo "✅ Done."
    exit 0
fi

# === Menu ===
echo ""
echo "📦 Found ${#INSTANCES[@]} OpenAlgo instance(s):"
i=1
for inst in "${INSTANCES[@]}"; do
    echo "$i) $inst"
    i=$((i+1))
done
echo "$i) 🚨 Remove ALL instances"
echo ""

read -p "Select an instance to remove [1-$i]: " CHOICE

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > $i )); then
    echo "❌ Invalid choice."
    exit 1
fi

if [ "$CHOICE" -eq "$i" ]; then
    read -p "⚠️ Are you sure you want to delete ALL OpenAlgo instances? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        failed=0
        for inst in "${INSTANCES[@]}"; do
            remove_instance "$inst" || failed=1
        done
    else
        echo "❌ Aborted."
        exit 1
    fi
else
    SELECTED="${INSTANCES[$((CHOICE - 1))]}"
    read -p "⚠️ Confirm removal of '$SELECTED'? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        remove_instance "$SELECTED" || exit 1
    else
        echo "❌ Aborted."
        exit 1
    fi
fi

reload_web
[ "${failed:-0}" -eq 0 ] || { echo "⚠ Some instances were not removed (backup failed) - see above"; exit 1; }
echo "✅ Done."
