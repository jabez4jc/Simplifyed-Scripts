#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_message() {
    local message="$1"
    local color="$2"
    echo -e "${color}${message}${NC}"
}

show_banner() {
    echo -e "${BLUE}"
    echo "  ██████╗ ██████╗ ███████╗███╗   ██╗ █████╗ ██╗      ██████╗  ██████╗ "
    echo " ██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔══██╗██║     ██╔════╝ ██╔═══██╗"
    echo " ██║   ██║██████╔╝███████╗██╔██╗ ██║███████║██║     ██║  ███╗██║   ██║"
    echo " ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██╔══██║██║     ██║   ██║██║   ██║"
    echo " ╚██████╔╝██╗     ███████╗██║ ╚████║██║  ██║███████╗╚██████╔╝╚██████╔╝"
    echo "  ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝╚═╝  ╚══════╝ ╚═════╝  ╚═════╝ "
    echo -e "${NC}"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    log_message "This script must be run as root (use sudo)" "$RED"
    exit 1
fi

show_banner

log_message "\n╔════════════════════════════════════════╗" "$BLUE"
log_message "║ INSTALLING OPENALGO REST API          ║" "$BLUE"
log_message "╚════════════════════════════════════════╝" "$BLUE"

# Step 1: Copy API script
log_message "\n📝 Step 1: Installing API script..." "$YELLOW"

if [ ! -f "openalgo-restart-api.py" ]; then
    log_message "❌ openalgo-restart-api.py not found in current directory" "$RED"
    log_message "Please ensure you're in the Simplifyed-Scripts directory" "$YELLOW"
    exit 1
fi

cp openalgo-restart-api.py /usr/local/bin/openalgo-restart-api.py
chmod +x /usr/local/bin/openalgo-restart-api.py

if [ -f "/usr/local/bin/openalgo-restart-api.py" ]; then
    log_message "✅ API script installed at /usr/local/bin/openalgo-restart-api.py" "$GREEN"
else
    log_message "❌ Failed to install API script" "$RED"
    exit 1
fi

# Step 2: Verify Python3
log_message "\n📝 Step 2: Checking Python3..." "$YELLOW"

if ! command -v python3 &> /dev/null; then
    log_message "❌ Python3 not found - Installing..." "$YELLOW"
    apt-get update > /dev/null 2>&1
    apt-get install -y python3 > /dev/null 2>&1
    
    if ! command -v python3 &> /dev/null; then
        log_message "❌ Failed to install Python3" "$RED"
        exit 1
    fi
fi

python_version=$(python3 --version 2>&1)
log_message "✅ $python_version found" "$GREEN"

# Step 3: Test API
log_message "\n📝 Step 3: Testing API..." "$YELLOW"

# Kill any existing processes
pkill -9 -f "python3.*openalgo-restart-api" 2>/dev/null || true
if ss -tlnp 2>/dev/null | grep -q ":8888 " || netstat -tlnp 2>/dev/null | grep -q ":8888 "; then
    fuser -k 8888/tcp 2>/dev/null || true
fi

sleep 2

# Start API in background
python3 /usr/local/bin/openalgo-restart-api.py 8888 > /tmp/api_test.log 2>&1 &
API_PID=$!
sleep 3

# Test connectivity
response=$(curl -s -m 5 http://localhost:8888/health 2>&1)

if echo "$response" | grep -q "healthy"; then
    log_message "✅ API test successful" "$GREEN"
    kill $API_PID 2>/dev/null || true
else
    log_message "❌ API test failed" "$RED"
    log_message "Error log:" "$YELLOW"
    cat /tmp/api_test.log
    kill $API_PID 2>/dev/null || true
    exit 1
fi

# Step 4: Summary
log_message "\n╔════════════════════════════════════════╗" "$GREEN"
log_message "║ ✅ API INSTALLATION COMPLETE          ║" "$GREEN"
log_message "╚════════════════════════════════════════╝" "$GREEN"

log_message "\n${YELLOW}Next Steps:${NC}"
log_message "1. Setup API as systemd service:" "$BLUE"
log_message "   ${GREEN}sudo ./setup-api.sh${NC}" "$BLUE"
log_message "" "$BLUE"
log_message "2. Or run setup-api.sh to access the menu:" "$BLUE"
log_message "   ${GREEN}sudo ./setup-api.sh${NC}" "$BLUE"
log_message "   Then select option 4 to setup everything" "$BLUE"

log_message "\n${YELLOW}Files installed:${NC}"
log_message "  /usr/local/bin/openalgo-restart-api.py" "$GREEN"

log_message "\n${YELLOW}Access the dashboard once configured:${NC}"
SERVER_IP=$(hostname -I | awk '{print $1}')
log_message "  http://$SERVER_IP:8888" "$GREEN"
