#!/bin/bash

# ============================================================
# Make All Scripts Executable
# ============================================================

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

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo -e "${BLUE}"
echo "  ██████╗ ██████╗ ███████╗███╗   ██╗ █████╗ ██╗      ██████╗  ██████╗ "
echo " ██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔══██╗██║     ██╔════╝ ██╔═══██╗"
echo " ██║   ██║██████╔╝███████╗██╔██╗ ██║███████║██║     ██║  ███╗██║   ██║"
echo " ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██╔══██║██║     ██║   ██║██║   ██║"
echo " ╚██████╔╝██╗     ███████╗██║ ╚████║██║  ██║███████╗╚██████╔╝╚██████╔╝"
echo "  ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝╚═╝  ╚══════╝ ╚═════╝  ╚═════╝ "
echo "               MAKE SCRIPTS EXECUTABLE UTILITY                         "
echo -e "${NC}"

log_message "\n📁 Working directory: $SCRIPT_DIR" "$BLUE"

# Array to track results
declare -a SUCCESS_SCRIPTS
declare -a FAILED_SCRIPTS
declare -a ALREADY_EXECUTABLE

log_message "\n🔍 Finding shell scripts...\n" "$BLUE"

# Find all .sh files in the current directory
for script in "$SCRIPT_DIR"/*.sh; do
    # Skip this script itself
    if [[ "$script" == "$SCRIPT_DIR/make-executable.sh" ]]; then
        continue
    fi
    
    # Get just the filename
    script_name=$(basename "$script")
    
    # Check if file exists and is a regular file
    if [ ! -f "$script" ]; then
        continue
    fi
    
    # Check if already executable
    if [ -x "$script" ]; then
        log_message "✓ Already executable: $script_name" "$GREEN"
        ALREADY_EXECUTABLE+=("$script_name")
        continue
    fi
    
    # Make the script executable
    if chmod +x "$script" 2>/dev/null; then
        log_message "✓ Made executable: $script_name" "$GREEN"
        SUCCESS_SCRIPTS+=("$script_name")
    else
        log_message "✗ Failed to make executable: $script_name" "$RED"
        FAILED_SCRIPTS+=("$script_name")
    fi
done

# Display summary
log_message "\n╔════════════════════════════════════╗" "$BLUE"
log_message "║          SUMMARY                   ║" "$BLUE"
log_message "╚════════════════════════════════════╝" "$BLUE"

if [ ${#SUCCESS_SCRIPTS[@]} -gt 0 ]; then
    log_message "\n✓ Successfully made executable (${#SUCCESS_SCRIPTS[@]}):" "$GREEN"
    for script in "${SUCCESS_SCRIPTS[@]}"; do
        log_message "  • $script" "$GREEN"
    done
fi

if [ ${#ALREADY_EXECUTABLE[@]} -gt 0 ]; then
    log_message "\n✓ Already executable (${#ALREADY_EXECUTABLE[@]}):" "$YELLOW"
    for script in "${ALREADY_EXECUTABLE[@]}"; do
        log_message "  • $script" "$YELLOW"
    done
fi

if [ ${#FAILED_SCRIPTS[@]} -gt 0 ]; then
    log_message "\n✗ Failed to make executable (${#FAILED_SCRIPTS[@]}):" "$RED"
    for script in "${FAILED_SCRIPTS[@]}"; do
        log_message "  • $script" "$RED"
    done
    log_message "\n⚠️  Note: You may need to run this script with sudo" "$YELLOW"
    exit 1
fi

# List all executable scripts
log_message "\n📋 All available scripts:" "$BLUE"
log_message "────────────────────────────────────" "$BLUE"

for script in "$SCRIPT_DIR"/*.sh; do
    if [ -x "$script" ] && [ "$(basename "$script")" != "make-executable.sh" ]; then
        script_name=$(basename "$script")
        log_message "  $script_name" "$BLUE"
    fi
done

log_message "\n✅ All scripts are now executable!" "$GREEN"
log_message "\n💡 You can now run scripts directly:" "$YELLOW"
log_message "   sudo ./oa-health-check.sh" "$YELLOW"
log_message "   sudo ./oa-backup.sh" "$YELLOW"
log_message "   sudo ./oa-update.sh" "$YELLOW"
log_message "   etc." "$YELLOW"
