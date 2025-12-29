#!/bin/bash

BASE_DIR="/var/python/openalgo-flask"

# Discover installed instances
INSTANCES=($(ls -1 "$BASE_DIR" 2>/dev/null))

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
    local DEPLOY_NAME="$1"
    local SERVICE_NAME="openalgo-$DEPLOY_NAME"

    echo "🔁 Restarting $SERVICE_NAME..."
    sudo systemctl restart "$SERVICE_NAME"
    if [ $? -eq 0 ]; then
        echo "✅ $DEPLOY_NAME restarted successfully."
    else
        echo "❌ Failed to restart $DEPLOY_NAME."
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