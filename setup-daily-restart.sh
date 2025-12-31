#!/bin/bash

# ============================================================
# Setup Daily Restart of All OpenAlgo Instances at 8 AM IST
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

# Banner
echo -e "${BLUE}"
echo "  ██████╗ ██████╗ ███████╗███╗   ██╗ █████╗ ██╗      ██████╗  ██████╗ "
echo " ██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔══██╗██║     ██╔════╝ ██╔═══██╗"
echo " ██║   ██║██████╔╝███████╗██╔██╗ ██║███████║██║     ██║  ███╗██║   ██║"
echo " ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██╔══██║██║     ██║   ██║██║   ██║"
echo " ╚██████╔╝██╗     ███████╗██║ ╚████║██║  ██║███████╗╚██████╔╝╚██████╔╝"
echo "  ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝╚═╝  ╚══════╝ ╚═════╝  ╚═════╝ "
echo "         SETUP DAILY RESTART CRON JOB (8 AM IST)                      "
echo -e "${NC}"

log_message "\n📋 This script will setup automatic daily restart of all OpenAlgo instances" "$BLUE"
log_message "   Restart Time: 8:00 AM IST (Daily)" "$BLUE"
log_message "   Timezone: Asia/Kolkata (IST)" "$BLUE"
echo ""

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log_message "❌ This script must be run with sudo" "$RED"
    log_message "   Usage: sudo ./setup-daily-restart.sh" "$YELLOW"
    exit 1
fi

read -p "Continue? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_message "❌ Setup cancelled by user" "$RED"
    exit 0
fi

# Get the script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Define paths
RESTART_SCRIPT="/usr/local/bin/openalgo-daily-restart.sh"
LOG_FILE="/var/log/openalgo-daily-restart.log"

# Create a restart script for cron
log_message "\n🔧 Creating automated restart script..." "$BLUE"

cat > "$RESTART_SCRIPT" << 'EOF'
#!/bin/bash

# ============================================================
# OpenAlgo Daily Restart Script (Called by Cron)
# ============================================================

BASE_DIR="/var/python/openalgo-flask"
LOG_FILE="/var/log/openalgo-daily-restart.log"

# Function to log messages
log_to_file() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log_to_file "Starting daily restart of all OpenAlgo instances"

# Get list of instances
INSTANCES=($(ls -1 "$BASE_DIR" 2>/dev/null | grep "^openalgo" | sort))

if [ ${#INSTANCES[@]} -eq 0 ]; then
    log_to_file "No OpenAlgo instances found"
    exit 0
fi

# Restart each instance
restart_count=0
for instance in "${INSTANCES[@]}"; do
    SERVICE_NAME="$instance"
    
    log_to_file "Restarting $SERVICE_NAME..."
    
    if systemctl restart "$SERVICE_NAME" 2>&1 | tee -a "$LOG_FILE"; then
        log_to_file "✓ Successfully restarted $SERVICE_NAME"
        ((restart_count++))
    else
        log_to_file "✗ Failed to restart $SERVICE_NAME"
    fi
    
    # Wait 2 seconds between restarts
    sleep 2
done

# Reload Nginx
log_to_file "Reloading Nginx..."
systemctl reload nginx

log_to_file "Daily restart completed. Restarted $restart_count instance(s)"
log_to_file "---"
EOF

chmod +x "$RESTART_SCRIPT"
log_message "✅ Created restart script at $RESTART_SCRIPT" "$GREEN"

# Create log file
log_message "📝 Creating log file..." "$BLUE"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 666 "$LOG_FILE"
log_message "✅ Created log file at $LOG_FILE" "$GREEN"

# Get current timezone
log_message "\n🌍 Checking system timezone..." "$BLUE"
CURRENT_TZ=$(timedatectl | grep "Time zone" | awk '{print $3}')
log_message "   Current timezone: $CURRENT_TZ" "$BLUE"

if [[ "$CURRENT_TZ" != "Asia/Kolkata" ]]; then
    log_message "⚠️  Warning: System timezone is not IST (Asia/Kolkata)" "$YELLOW"
    log_message "   Cron will use system timezone: $CURRENT_TZ" "$YELLOW"
    
    read -p "Change timezone to IST? (y/N): " change_tz
    if [[ "$change_tz" =~ ^[Yy]$ ]]; then
        log_message "Changing timezone to IST..." "$BLUE"
        timedatectl set-timezone Asia/Kolkata
        log_message "✅ Timezone changed to IST" "$GREEN"
    fi
else
    log_message "✅ System timezone is already IST" "$GREEN"
fi

# Setup cron job
log_message "\n⏰ Setting up cron job..." "$BLUE"

# Remove existing cron job if present
CRON_ID="# OpenAlgo Daily Restart (8 AM IST)"
CRON_CMD="0 8 * * * $RESTART_SCRIPT"

# Check if cron job already exists
if crontab -l 2>/dev/null | grep -q "openalgo-daily-restart.sh"; then
    log_message "⚠️  Existing cron job found, removing..." "$YELLOW"
    (crontab -l 2>/dev/null | grep -v "openalgo-daily-restart.sh" | crontab -) 2>/dev/null || true
fi

# Add new cron job
log_message "   Adding cron job: 0 8 * * * (Daily at 8 AM)" "$BLUE"
(crontab -l 2>/dev/null; echo "$CRON_ID"; echo "$CRON_CMD") | crontab -
check_status=$?

if [ $check_status -eq 0 ]; then
    log_message "✅ Cron job setup successfully" "$GREEN"
else
    log_message "❌ Failed to setup cron job" "$RED"
    exit 1
fi

# Verify cron job
log_message "\n✅ Verifying cron job setup..." "$BLUE"
if crontab -l 2>/dev/null | grep -q "openalgo-daily-restart.sh"; then
    log_message "✅ Cron job verified and active" "$GREEN"
    echo ""
    crontab -l | grep -A1 "OpenAlgo Daily Restart"
else
    log_message "⚠️  Could not verify cron job" "$YELLOW"
fi

# Summary
log_message "\n╔════════════════════════════════════════════════════════╗" "$GREEN"
log_message "║      DAILY RESTART CRON JOB SETUP COMPLETED           ║" "$GREEN"
log_message "╚════════════════════════════════════════════════════════╝" "$GREEN"

log_message "\n📋 CONFIGURATION DETAILS:" "$YELLOW"
log_message "   Restart Time: 8:00 AM IST (Daily)" "$BLUE"
log_message "   Timezone: Asia/Kolkata" "$BLUE"
log_message "   Restart Script: $RESTART_SCRIPT" "$BLUE"
log_message "   Log File: $LOG_FILE" "$BLUE"
log_message "   Cron Schedule: 0 8 * * * (Every day at 8 AM)" "$BLUE"

log_message "\n📚 USEFUL COMMANDS:" "$YELLOW"
log_message "   View cron jobs: crontab -l" "$BLUE"
log_message "   Edit cron jobs: crontab -e" "$BLUE"
log_message "   View restart logs: tail -f $LOG_FILE" "$BLUE"
log_message "   Remove cron job: crontab -r" "$BLUE"

log_message "\n🔍 TO CHANGE RESTART TIME:" "$YELLOW"
log_message "   Edit crontab: sudo crontab -e" "$BLUE"
log_message "   Change '0 8' to desired hour and minute:" "$BLUE"
log_message "   Examples:" "$BLUE"
log_message "     • 30 7 = 7:30 AM" "$BLUE"
log_message "     • 0 9 = 9:00 AM" "$BLUE"
log_message "     • 30 10 = 10:30 AM" "$BLUE"

log_message "\n💡 NOTES:" "$YELLOW"
log_message "   • Ensure system timezone is set to IST (Asia/Kolkata)" "$YELLOW"
log_message "   • Check logs for any restart issues: tail -f $LOG_FILE" "$YELLOW"
log_message "   • Restart process typically takes 1-2 minutes" "$YELLOW"
log_message "   • Instances will be briefly unavailable during restart" "$YELLOW"

log_message "\n✅ Setup complete! All OpenAlgo instances will restart at 8 AM IST daily." "$GREEN"
