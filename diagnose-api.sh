#!/bin/bash

# ============================================================
# Diagnose OpenAlgo REST API Issues
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

echo -e "${BLUE}"
echo "  ██████╗ ██████╗ ███████╗███╗   ██╗ █████╗ ██╗      ██████╗  ██████╗ "
echo " ██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔══██╗██║     ██╔════╝ ██╔═══██╗"
echo " ██║   ██║██████╔╝███████╗██╔██╗ ██║███████║██║     ██║  ███╗██║   ██║"
echo " ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██╔══██║██║     ██║   ██║██║   ██║"
echo " ╚██████╔╝██╗     ███████╗██║ ╚████║██║  ██║███████╗╚██████╔╝╚██████╔╝"
echo "  ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝╚═╝  ╚══════╝ ╚═════╝  ╚═════╝ "
echo "                  API DIAGNOSTIC TOOL                                 "
echo -e "${NC}"

log_message "\n📋 Checking API service and configuration...\n" "$BLUE"

# Check if Python3 is installed
log_message "1️⃣  Checking Python3 installation..." "$YELLOW"
if command -v python3 &> /dev/null; then
    python_version=$(python3 --version 2>&1)
    log_message "   ✅ Python3 found: $python_version" "$GREEN"
else
    log_message "   ❌ Python3 NOT found - Installing..." "$RED"
    sudo apt-get update > /dev/null 2>&1
    sudo apt-get install -y python3 > /dev/null 2>&1
    if command -v python3 &> /dev/null; then
        log_message "   ✅ Python3 installed successfully" "$GREEN"
    else
        log_message "   ❌ Failed to install Python3" "$RED"
        exit 1
    fi
fi

# Check if API script exists
log_message "\n2️⃣  Checking API script..." "$YELLOW"
if [ -f "/usr/local/bin/openalgo-restart-api.py" ]; then
    log_message "   ✅ API script found at /usr/local/bin/openalgo-restart-api.py" "$GREEN"
    
    # Check if script is executable
    if [ -x "/usr/local/bin/openalgo-restart-api.py" ]; then
        log_message "   ✅ API script is executable" "$GREEN"
    else
        log_message "   ⚠️  API script is not executable - fixing..." "$YELLOW"
        sudo chmod +x /usr/local/bin/openalgo-restart-api.py
        log_message "   ✅ Fixed permissions" "$GREEN"
    fi
else
    log_message "   ❌ API script not found" "$RED"
    log_message "   Please run: sudo ./setup-remote-restart.sh" "$YELLOW"
    exit 1
fi

# Check if systemd service exists
log_message "\n3️⃣  Checking systemd service..." "$YELLOW"
if [ -f "/etc/systemd/system/openalgo-restart-api.service" ]; then
    log_message "   ✅ Service file found" "$GREEN"
    
    # Check service status
    if systemctl is-active --quiet openalgo-restart-api; then
        log_message "   ✅ Service is RUNNING" "$GREEN"
        
        # Get service info
        status=$(systemctl status openalgo-restart-api 2>&1)
        port=$(echo "$status" | grep -oP ':\K\d+(?=\)?)' | head -1)
        
        if [ -z "$port" ]; then
            port=$(grep "ExecStart" /etc/systemd/system/openalgo-restart-api.service | grep -oP '\d{4,5}$' || echo "8888")
        fi
        
        log_message "   Port: $port" "$BLUE"
    else
        log_message "   ❌ Service is NOT RUNNING - Starting..." "$RED"
        
        sudo systemctl daemon-reload
        sudo systemctl enable openalgo-restart-api
        sudo systemctl start openalgo-restart-api
        
        sleep 2
        
        if systemctl is-active --quiet openalgo-restart-api; then
            log_message "   ✅ Service started successfully" "$GREEN"
        else
            log_message "   ❌ Failed to start service" "$RED"
            log_message "\n   Service logs:" "$YELLOW"
            sudo journalctl -u openalgo-restart-api -n 10 --no-pager | sed 's/^/   /'
        fi
    fi
else
    log_message "   ❌ Service file not found" "$RED"
    log_message "   Please run: sudo ./setup-remote-restart.sh" "$YELLOW"
    exit 1
fi

# Check port availability
log_message "\n4️⃣  Checking port 8888..." "$YELLOW"
if netstat -tuln 2>/dev/null | grep -q ":8888 " || ss -tuln 2>/dev/null | grep -q ":8888 "; then
    log_message "   ✅ Port 8888 is listening" "$GREEN"
    
    # Get the service listening on 8888
    listening_service=$(ss -tuln 2>/dev/null | grep ":8888 " | awk '{print $NF}')
    if [ ! -z "$listening_service" ]; then
        log_message "   Process: $listening_service" "$BLUE"
    fi
else
    log_message "   ❌ Port 8888 is NOT listening" "$RED"
    log_message "\n   All listening ports:" "$YELLOW"
    ss -tuln | grep LISTEN | head -10 | sed 's/^/   /'
fi

# Check firewall
log_message "\n5️⃣  Checking firewall..." "$YELLOW"
if command -v ufw &> /dev/null; then
    if sudo ufw status | grep -q "inactive"; then
        log_message "   ℹ️  UFW firewall is INACTIVE" "$BLUE"
    else
        if sudo ufw status | grep -q "8888"; then
            log_message "   ✅ Port 8888 allowed in UFW" "$GREEN"
        else
            log_message "   ⚠️  Port 8888 may not be allowed - Adding..." "$YELLOW"
            sudo ufw allow 8888 > /dev/null 2>&1
            log_message "   ✅ Port 8888 added to UFW" "$GREEN"
        fi
    fi
else
    log_message "   ℹ️  UFW not found - checking iptables..." "$BLUE"
    if command -v iptables &> /dev/null; then
        if sudo iptables -L -n | grep -q "8888"; then
            log_message "   ✅ Port 8888 appears to be open in iptables" "$GREEN"
        else
            log_message "   ⚠️  Port 8888 may not be open in iptables" "$YELLOW"
        fi
    fi
fi

# Test API connectivity
log_message "\n6️⃣  Testing API connectivity..." "$YELLOW"
response=$(curl -s -m 5 http://localhost:8888/health 2>&1 | head -1)
if [ $? -eq 0 ] && echo "$response" | grep -q "healthy"; then
    log_message "   ✅ API is responding to localhost" "$GREEN"
    log_message "   Response: $response" "$BLUE"
else
    log_message "   ❌ API not responding" "$RED"
    
    # Try to start API manually
    log_message "\n   Attempting manual start..." "$YELLOW"
    
    # Kill any existing processes
    sudo pkill -9 -f "python3.*openalgo-restart-api" 2>/dev/null || true
    
    # Kill by port if still listening
    if ss -tlnp 2>/dev/null | grep -q ":8888 " || netstat -tlnp 2>/dev/null | grep -q ":8888 "; then
        sudo fuser -k 8888/tcp 2>/dev/null || true
    fi
    
    sleep 2
    
    # Start API in background
    sudo /usr/bin/python3 /usr/local/bin/openalgo-restart-api.py 8888 > /tmp/api.log 2>&1 &
    sleep 3
    
    # Test again
    response=$(curl -s -m 5 http://localhost:8888/health 2>&1 | head -1)
    if [ $? -eq 0 ]; then
        log_message "   ✅ API started successfully" "$GREEN"
        log_message "   Response: $response" "$BLUE"
        
        # Restart systemd service
        sudo systemctl restart openalgo-restart-api
    else
        log_message "   ❌ Still not responding" "$RED"
        log_message "\n   API error log:" "$YELLOW"
        cat /tmp/api.log | sed 's/^/   /'
    fi
fi

# Summary
log_message "\n╔════════════════════════════════════════════════════════╗" "$GREEN"
log_message "║                DIAGNOSTIC SUMMARY                      ║" "$GREEN"
log_message "╚════════════════════════════════════════════════════════╝" "$GREEN"

log_message "\n✅ NEXT STEPS:" "$GREEN"
log_message "   1. Access the web UI at:" "$BLUE"
log_message "      http://$(hostname -I | awk '{print $1}'):8888" "$GREEN"
echo ""
log_message "   2. Or test with curl:" "$BLUE"
log_message "      curl http://localhost:8888/health" "$GREEN"
echo ""
log_message "   3. Get instance list:" "$BLUE"
log_message "      curl http://localhost:8888/api/instances" "$GREEN"
echo ""

log_message "📝 TROUBLESHOOTING:" "$YELLOW"
log_message "   If still not working:" "$BLUE"
log_message "   1. Check service logs: sudo journalctl -u openalgo-restart-api -f" "$GREEN"
log_message "   2. Restart service: sudo systemctl restart openalgo-restart-api" "$GREEN"
log_message "   3. Check port: sudo netstat -tuln | grep 8888" "$GREEN"
log_message "   4. Check firewall: sudo ufw status" "$GREEN"
