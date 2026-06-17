#!/bin/bash
# ============================================================
# OpenAlgo Utility Script - Configure 4GB Swap on Ubuntu
# ============================================================

set -e

SWAPFILE="/swapfile"
SWAPSIZE="4G"

echo "🔁 Checking existing swap configuration..."

# Disable any existing swap
if grep -q "$SWAPFILE" /etc/fstab; then
    echo "🧹 Disabling existing swap..."
    sudo swapoff -a || true
    sudo sed -i "\|$SWAPFILE|d" /etc/fstab
fi

# Remove old swapfile if it exists
if [ -f "$SWAPFILE" ]; then
    echo "🗑️  Removing old swap file..."
    sudo rm -f $SWAPFILE
fi

# Create new 4GB swap file
echo "🛠️  Creating new 4GB swap file..."
sudo fallocate -l $SWAPSIZE $SWAPFILE

# Secure permissions
sudo chmod 600 $SWAPFILE

# Format as swap
sudo mkswap $SWAPFILE

# Enable swap immediately
sudo swapon $SWAPFILE

# Persist swap in fstab
echo "$SWAPFILE none swap sw 0 0" | sudo tee -a /etc/fstab > /dev/null

# Set swappiness to 15
sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null <<'EOF'
vm.swappiness=15
EOF
sudo sysctl -p /etc/sysctl.d/99-swappiness.conf

# Display swap summary
echo "✅ Swap configuration complete!"
echo "-----------------------------------"
sudo swapon --show
free -h
echo "-----------------------------------"
echo "💾 4GB Swap is now active and permanent."
