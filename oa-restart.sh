#!/bin/bash

BASE_DIR="/var/python/openalgo-flask"

# Resolve service name for an instance (new installs use openalgo-<domain>)
get_service_name() {
    local instance_name="$1"
    local env_file="$BASE_DIR/$instance_name/.env"
    local domain=""

    if [ -f "$env_file" ]; then
        domain=$(grep -E "^DOMAIN *=" "$env_file" | head -1 | cut -d'=' -f2- | tr -d "' \"\r")
    fi

    if [ -n "$domain" ]; then
        echo "openalgo-${domain//./-}"
    else
        echo "$instance_name"
    fi
}

# Discover installed instances (exclude symlinks)
INSTANCES=($(find "$BASE_DIR" -maxdepth 1 -type d -name "openalgo[0-9]*" -printf "%f\n" 2>/dev/null | sort))

if [ ${#INSTANCES[@]} -eq 0 ]; then
    echo "❌ No OpenAlgo instances found in $BASE_DIR"
    exit 1
fi

# Menu
echo ""
echo "🔄 Available OpenAlgo instances:"
i=1
for inst in "${INSTANCES[@]}"; do
    echo "$i) $inst"
    i=$((i+1))
done
echo "$i) 🚀 Restart ALL instances"
echo ""

read -p "Select an instance to restart [1-$i]: " CHOICE

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > $i )); then
    echo "❌ Invalid choice."
    exit 1
fi

restart_instance() {
    local INSTANCE_NAME="$1"
    local SERVICE_NAME
    SERVICE_NAME=$(get_service_name "$INSTANCE_NAME")

    local total_deleted=0
    local log_dir
    for log_dir in "$BASE_DIR/$INSTANCE_NAME/log" "$BASE_DIR/$INSTANCE_NAME/logs"; do
        if [ -d "$log_dir" ]; then
            count=$(find "$log_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
            if [ "$count" -gt 0 ]; then
                find "$log_dir" -type f -delete 2>/dev/null
                echo "🧹 Cleared $count log file(s) in $log_dir"
                total_deleted=$((total_deleted + count))
            fi
        fi
    done
    if [ "$total_deleted" -eq 0 ]; then
        echo "🧹 No instance log files to clean for $INSTANCE_NAME"
    fi

    echo "🔁 Restarting $SERVICE_NAME..."
    sudo systemctl restart "$SERVICE_NAME"
    if [ $? -eq 0 ]; then
        echo "✅ $INSTANCE_NAME restarted successfully."
    else
        echo "❌ Failed to restart $INSTANCE_NAME."
    fi
}

if [ "$CHOICE" -eq "$i" ]; then
    echo "🚀 Restarting ALL OpenAlgo instances..."
    for inst in "${INSTANCES[@]}"; do
        restart_instance "$inst"
    done
else
    SELECTED="${INSTANCES[$((CHOICE - 1))]}"
    restart_instance "$SELECTED"
fi

echo "🔄 Reloading Nginx for good measure..."
sudo systemctl reload nginx

echo "✅ Done."
