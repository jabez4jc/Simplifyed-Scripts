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
    else
        echo "$fallback_name"
    fi
}

clean_instance_logs() {
    local instance_name="$1"
    local total_deleted=0
    local log_dir

    for log_dir in "$BASE_DIR/$instance_name/log" "$BASE_DIR/$instance_name/logs"; do
        if [ -d "$log_dir" ]; then
            local count
            count=$(find "$log_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
            if [ "$count" -gt 0 ]; then
                find "$log_dir" -type f -delete 2>/dev/null
                log_to_file "🧹 Cleared $count log file(s) in $log_dir"
                total_deleted=$((total_deleted + count))
            fi
        fi
    done

    if [ "$total_deleted" -eq 0 ]; then
        log_to_file "No instance log files to clean for $instance_name"
    fi
}

log_to_file "Starting daily restart of all OpenAlgo instances"

# Get list of instances (exclude symlinks)
INSTANCES=($(find "$BASE_DIR" -maxdepth 1 -type d -name "openalgo*" -printf "%f\n" 2>/dev/null | sort))

if [ ${#INSTANCES[@]} -eq 0 ]; then
    log_to_file "No OpenAlgo instances found"
    exit 0
fi

# Restart each instance
restart_count=0
for instance in "${INSTANCES[@]}"; do
    SERVICE_NAME=$(get_service_name "$BASE_DIR/$instance" "$instance")

    log_to_file "Cleaning logs for $SERVICE_NAME..."
    clean_instance_logs "$instance"
    
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

# Check if crontab is available, if not install it
if ! command -v crontab &> /dev/null; then
    log_message "   cron service not found, installing..." "$YELLOW"
    
    # Install cron based on system
    if command -v apt-get &> /dev/null; then
        log_message "   Installing cron using apt-get..." "$BLUE"
        apt-get update > /dev/null 2>&1
        apt-get install -y cron > /dev/null 2>&1
    elif command -v yum &> /dev/null; then
        log_message "   Installing cron using yum..." "$BLUE"
        yum install -y cronie > /dev/null 2>&1
    else
        log_message "❌ Could not install cron - unsupported package manager" "$RED"
        exit 1
    fi
    
    # Start cron service
    log_message "   Starting cron service..." "$BLUE"
    if systemctl is-active --quiet cron; then
        true
    elif systemctl is-active --quiet crond; then
        true
    else
        systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null || true
    fi
    
    log_message "✅ Cron service installed and started" "$GREEN"
fi

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
