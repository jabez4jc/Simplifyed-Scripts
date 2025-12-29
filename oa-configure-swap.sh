#!/bin/bash

# ============================================================
# OpenAlgo Utility Script - Configure Custom Swap Size
# ============================================================

set -e

SWAPFILE="/swapfile"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to log messages
log_message() {
    local message="$1"
    local color="$2"
    echo -e "${color}${message}${NC}"
}

# Function to validate swap size input
validate_swap_size() {
    local size="$1"
    
    # Check if input is empty
    if [ -z "$size" ]; then
        log_message "❌ Error: Swap size cannot be empty" "$RED"
        return 1
    fi
    
    # Check if input is a positive number
    if ! [[ "$size" =~ ^[0-9]+$ ]]; then
        log_message "❌ Error: Swap size must be a positive integer" "$RED"
        return 1
    fi
    
    # Check if size is within reasonable limits (1GB to 512GB)
    if [ "$size" -lt 1 ] || [ "$size" -gt 512 ]; then
        log_message "❌ Error: Swap size must be between 1 and 512 GB" "$RED"
        return 1
    fi
    
    return 0
}

# Function to check available disk space
check_disk_space() {
    local swap_size_gb="$1"
    local swap_size_bytes=$((swap_size_gb * 1024 * 1024 * 1024))
    
    local available_bytes=$(df / | tail -1 | awk '{print $4 * 1024}')
    local available_gb=$((available_bytes / (1024 * 1024 * 1024)))
    
    # Add 10% buffer
    local required_bytes=$((swap_size_bytes + (swap_size_bytes / 10)))
    
    if [ "$available_bytes" -lt "$required_bytes" ]; then
        log_message "❌ Error: Insufficient disk space" "$RED"
        log_message "   Required: ~$((required_bytes / (1024 * 1024 * 1024)))GB (including buffer)" "$RED"
        log_message "   Available: ${available_gb}GB" "$RED"
        return 1
    fi
    
    return 0
}

# Function to get current swap info
get_current_swap_info() {
    local total=$(free -h | grep Swap | awk '{print $2}')
    local used=$(free -h | grep Swap | awk '{print $3}')
    
    log_message "\n📊 Current Swap Configuration:" "$BLUE"
    log_message "   Total: $total" "$BLUE"
    log_message "   Used: $used" "$BLUE"
    
    if [ -f "$SWAPFILE" ]; then
        local size=$(ls -lh "$SWAPFILE" | awk '{print $5}')
        log_message "   Swapfile: $SWAPFILE ($size)" "$BLUE"
    fi
}

# Function to display disk space information
get_disk_space_info() {
    log_message "\n💾 Available Disk Space:" "$BLUE"
    
    # Get root filesystem info
    local df_output=$(df -h / | tail -1)
    local total=$(echo "$df_output" | awk '{print $2}')
    local used=$(echo "$df_output" | awk '{print $3}')
    local available=$(echo "$df_output" | awk '{print $4}')
    local percent=$(echo "$df_output" | awk '{print $5}')
    local filesystem=$(echo "$df_output" | awk '{print $1}')
    
    log_message "   Filesystem: $filesystem" "$BLUE"
    log_message "   Total: $total" "$BLUE"
    log_message "   Used: $used ($percent)" "$BLUE"
    log_message "   Available: $available" "$BLUE"
    
    # Convert available to GB for reference
    local available_gb=$(echo "$available" | sed 's/G//' | sed 's/M.*/0/')
    if [[ "$available_gb" == "0" ]]; then
        available_gb=$(echo "$available" | sed 's/T//' | awk '{printf "%.0f", $1 * 1024}')
    fi
    
    # Show recommended swap sizes
    log_message "\n📋 Recommended Swap Sizes:" "$YELLOW"
    log_message "   Based on available space ($available):" "$YELLOW"
    
    local available_numeric=$(echo "$available" | sed 's/[A-Z].*//g')
    if [[ "$available" == *"T"* ]]; then
        available_numeric=$(echo "$available" | sed 's/T.*//' | awk '{printf "%.0f", $1 * 1024}')
        log_message "   • Conservative (50% of available): ~$((available_numeric / 2))GB" "$YELLOW"
        log_message "   • Moderate (25% of available): ~$((available_numeric / 4))GB" "$YELLOW"
    elif [[ "$available" == *"G"* ]]; then
        available_numeric=$(echo "$available" | sed 's/G.*//')
        log_message "   • Conservative (50% of available): ~$((available_numeric / 2))GB" "$YELLOW"
        log_message "   • Moderate (25% of available): ~$((available_numeric / 4))GB" "$YELLOW"
    fi
}

# Main execution
main() {
    echo -e "${BLUE}"
    echo "  ██████╗ ██████╗ ███████╗███╗   ██╗ █████╗ ██╗      ██████╗  ██████╗ "
    echo " ██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔══██╗██║     ██╔════╝ ██╔═══██╗"
    echo " ██║   ██║██████╔╝███████╗██╔██╗ ██║███████║██║     ██║  ███╗██║   ██║"
    echo " ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██╔══██║██║     ██║   ██║██║   ██║"
    echo " ╚██████╔╝██╗     ███████╗██║ ╚████║██║  ██║███████╗╚██████╔╝╚██████╔╝"
    echo "  ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝╚═╝  ╚══════╝ ╚═════╝  ╚═════╝ "
    echo "                  SWAP CONFIGURATION UTILITY                          "
    echo -e "${NC}"
    
    # Show current swap info
    get_current_swap_info
    
    # Show disk space info
    get_disk_space_info
    
    # Get swap size from arguments or prompt user
    local swap_size_gb
    
    if [ $# -eq 0 ]; then
        # Interactive mode
        log_message "\n📝 Enter desired swap size (in GB)" "$BLUE"
        read -p "Enter swap size in GB [default: 4]: " swap_size_gb
        
        # Use default if empty
        if [ -z "$swap_size_gb" ]; then
            swap_size_gb=4
            log_message "Using default: 4 GB" "$YELLOW"
        fi
    else
        swap_size_gb="$1"
    fi
    
    # Validate swap size
    if ! validate_swap_size "$swap_size_gb"; then
        exit 1
    fi
    
    SWAPSIZE="${swap_size_gb}G"
    
    log_message "\n🔍 Validating disk space..." "$BLUE"
    if ! check_disk_space "$swap_size_gb"; then
        exit 1
    fi
    
    log_message "✅ Sufficient disk space available" "$GREEN"
    
    # Confirmation
    log_message "\n⚠️  Swap Configuration Details:" "$YELLOW"
    log_message "   Size: ${swap_size_gb}GB" "$YELLOW"
    log_message "   Location: $SWAPFILE" "$YELLOW"
    log_message "   This will replace any existing swap configuration" "$YELLOW"
    
    read -p "Continue? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_message "❌ Cancelled by user" "$RED"
        exit 0
    fi
    
    log_message "\n🔁 Checking existing swap configuration..." "$BLUE"
    
    # Disable any existing swap
    if grep -q "$SWAPFILE" /etc/fstab; then
        log_message "🧹 Disabling existing swap..." "$BLUE"
        sudo swapoff -a || true
        sudo sed -i "\|$SWAPFILE|d" /etc/fstab
    fi
    
    # Remove old swapfile if it exists
    if [ -f "$SWAPFILE" ]; then
        log_message "🗑️  Removing old swap file..." "$BLUE"
        sudo rm -f "$SWAPFILE"
    fi
    
    # Create new swap file
    log_message "\n🛠️  Creating new ${swap_size_gb}GB swap file..." "$BLUE"
    sudo fallocate -l "$SWAPSIZE" "$SWAPFILE"
    
    if [ $? -ne 0 ]; then
        log_message "❌ Failed to allocate swap space" "$RED"
        exit 1
    fi
    
    # Secure permissions
    log_message "🔐 Setting permissions..." "$BLUE"
    sudo chmod 600 "$SWAPFILE"
    
    # Format as swap
    log_message "📝 Formatting swap..." "$BLUE"
    sudo mkswap "$SWAPFILE"
    
    # Enable swap immediately
    log_message "⚡ Enabling swap..." "$BLUE"
    sudo swapon "$SWAPFILE"
    
    # Persist swap in fstab
    log_message "💾 Persisting swap configuration..." "$BLUE"
    echo "$SWAPFILE none swap sw 0 0" | sudo tee -a /etc/fstab > /dev/null
    
    # Display swap summary
    log_message "\n✅ Swap configuration complete!" "$GREEN"
    log_message "-----------------------------------" "$GREEN"
    sudo swapon --show
    echo ""
    free -h
    log_message "-----------------------------------" "$GREEN"
    log_message "💾 ${swap_size_gb}GB Swap is now active and permanent." "$GREEN"
}

main "$@"
