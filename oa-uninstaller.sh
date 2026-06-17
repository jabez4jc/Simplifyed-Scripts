#!/bin/bash

# === CONFIG ===
BASE_DIR="/var/python/openalgo-flask"
NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"

# === Functions ===

# Extract domain from DEPLOY_NAME
extract_domain() {
    echo "$1" | sed 's/-[^-]*$//' | sed 's/-/./g'
}

get_service_name() {
    local instance_dir="$1"
    local fallback_name="$2"
    local env_file="$instance_dir/.env"
    local domain=""

    if [ -f "$env_file" ]; then
        domain=$(grep -E "^DOMAIN=" "$env_file" | head -1 | cut -d'=' -f2- | tr -d "'" | tr -d '"')
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
    local SERVICE_NAME
    SERVICE_NAME=$(get_service_name "$INSTANCE_DIR" "$DEPLOY_NAME")
    local DOMAIN=$(extract_domain "$DEPLOY_NAME")
    local NGINX_CONF="$NGINX_AVAILABLE/$DOMAIN.conf"
    local NGINX_LINK="$NGINX_ENABLED/$DOMAIN.conf"
    local SOCKET_FILE="$INSTANCE_DIR/openalgo.sock"

    echo "🔧 Removing instance: $DEPLOY_NAME"

    echo "🛑 Stopping service: $SERVICE_NAME"
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null
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

    echo "🧹 Cleaning nginx config for domain: $DOMAIN"
    sudo rm -f "$NGINX_CONF" "$NGINX_LINK"

    if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
        echo "🧯 Removing SSL certificate for $DOMAIN"
        sudo certbot delete --cert-name "$DOMAIN" --non-interactive
    fi

    echo "✅ $DEPLOY_NAME removed"
}

# === Script Entry ===

echo "🔍 Looking for OpenAlgo instances..."
if [ ! -d "$BASE_DIR" ]; then
    echo "❌ No instances found in $BASE_DIR"
    exit 1
fi

INSTANCES=($(find "$BASE_DIR" -maxdepth 1 -type d -name "openalgo[0-9]*" -printf "%f\n" 2>/dev/null | sort))
if [ ${#INSTANCES[@]} -eq 0 ]; then
    echo "❌ No OpenAlgo instances installed."
    exit 1
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
        for inst in "${INSTANCES[@]}"; do
            remove_instance "$inst"
        done
    else
        echo "❌ Aborted."
        exit 1
    fi
else
    SELECTED="${INSTANCES[$((CHOICE - 1))]}"
    read -p "⚠️ Confirm removal of '$SELECTED'? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        remove_instance "$SELECTED"
    else
        echo "❌ Aborted."
        exit 1
    fi
fi

# Reload systemd and nginx
echo "🔄 Reloading systemd and nginx..."
sudo systemctl daemon-reload
sudo systemctl restart nginx

echo "✅ Done."
