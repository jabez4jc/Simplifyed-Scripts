#!/bin/bash

# API Manager - Simple interactive API setup and management
# Run with: sudo ./api-manager.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "This script must be run with sudo: sudo ./api-manager.sh"
    exit 1
fi

show_menu() {
    clear
    echo -e "${BLUE}"
    echo "  ██████╗ ██████╗ ███████╗███╗   ██╗ █████╗ ██╗      ██████╗  ██████╗ "
    echo " ██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔══██╗██║     ██╔════╝ ██╔═══██╗"
    echo " ██║   ██║██████╔╝███████╗██╔██╗ ██║███████║██║     ██║  ███╗██║   ██║"
    echo " ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██╔══██║██║     ██║   ██║██║   ██║"
    echo " ╚██████╔╝██╗     ███████╗██║ ╚████║██║  ██║███████╗╚██████╔╝╚██████╔╝"
    echo "  ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝╚═╝  ╚══════╝ ╚═════╝  ╚═════╝ "
    echo -e "${NC}"
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  OPENALGO API MANAGER${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo ""
}

menu_main() {
    show_menu
    echo "1) Setup / Update OpenAlgo Manager"
    echo "2) Show Status & URL"
    echo "3) View Logs"
    echo "4) Exit"
    echo ""
    read -p "Select option [1-4]: " choice
    echo ""
    
    case $choice in
        1) setup_update ;;
        2) show_status ;;
        3) show_logs ;;
        4) exit 0 ;;
        *) echo "Invalid option"; sleep 2; menu_main ;;
    esac
}

install_api() {
    echo -e "${YELLOW}Installing API...${NC}"
    
    API_FILE=""
    
    # Try to find the API script
    if [ -f "openalgo-restart-api.py" ]; then
        API_FILE="openalgo-restart-api.py"
    elif [ -f "$(dirname "$0")/openalgo-restart-api.py" ]; then
        API_FILE="$(dirname "$0")/openalgo-restart-api.py"
    else
        echo -e "${RED}❌ openalgo-restart-api.py not found${NC}"
        return 1
    fi
    
    # Copy the file
    cp "$API_FILE" /usr/local/bin/openalgo-restart-api.py 2>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to copy API script${NC}"
        return 1
    fi
    
    chmod +x /usr/local/bin/openalgo-restart-api.py
    
    if [ -f "/usr/local/bin/openalgo-restart-api.py" ]; then
        echo -e "${GREEN}✅ API installed${NC}"
        return 0
    else
        echo -e "${RED}❌ Installation failed${NC}"
        return 1
    fi
}

setup_service() {
    echo -e "${YELLOW}Setting up systemd service...${NC}"
    
    # Check if API is installed
    if [ ! -f "/usr/local/bin/openalgo-restart-api.py" ]; then
        echo -e "${RED}❌ API script not found. Please run 'Install API' first.${NC}"
        return 1
    fi
    
    if systemctl is-active --quiet openalgo-restart-api; then
        echo -e "${YELLOW}Stopping running service: openalgo-restart-api${NC}"
        systemctl stop openalgo-restart-api
        sleep 2
    fi

    # Create service file
    cat > /etc/systemd/system/openalgo-restart-api.service <<'SVCEOF'
[Unit]
Description=OpenAlgo REST API for Instance Management
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/bin
ExecStart=/usr/bin/python3 /usr/local/bin/openalgo-restart-api.py 8888
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to create service file${NC}"
        return 1
    fi
    
    # Reload systemd
    systemctl daemon-reload
    systemctl enable openalgo-restart-api
    
    # Kill any existing processes using the port or script
    pkill -9 -f "openalgo-restart-api.py" 2>/dev/null || true
    fuser -k 8888/tcp 2>/dev/null || true
    if command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":8888 "; then
            fuser -k 8888/tcp 2>/dev/null || true
        fi
    fi
    sleep 2
    
    # Start service
    systemctl start openalgo-restart-api
    sleep 3
    
    if systemctl is-active --quiet openalgo-restart-api; then
        echo -e "${GREEN}✅ Service started and will auto-start on boot${NC}"
        return 0
    else
        echo -e "${RED}❌ Service failed to start${NC}"
        echo -e "${YELLOW}Service logs:${NC}"
        journalctl -u openalgo-restart-api -n 20 --no-pager
        return 1
    fi
}

setup_firewall() {
    echo -e "${YELLOW}Configuring firewall...${NC}"
    
    if command -v ufw &>/dev/null; then
        ufw allow 8888/tcp > /dev/null 2>&1
        ufw allow 8888/udp > /dev/null 2>&1
        echo -e "${GREEN}✅ Port 8888 opened in UFW${NC}"
    else
        echo -e "${BLUE}ℹ️  UFW not found, skipping firewall setup${NC}"
    fi
}

setup_update() {
    clear
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  SETUP / UPDATE${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo ""

    echo -e "${YELLOW}Linking scripts to /usr/local/bin...${NC}"
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    if [ -d "$script_dir" ]; then
        ln -sf "$script_dir/"*.sh /usr/local/bin/ 2>/dev/null
        echo -e "${GREEN}✅ Scripts linked${NC}"
    else
        echo -e "${RED}❌ Script directory not found${NC}"
    fi
    echo ""

    install_api || { read -p "Press Enter to continue..."; menu_main; }
    echo ""
    setup_service || { read -p "Press Enter to continue..."; menu_main; }
    echo ""
    setup_firewall
    echo ""
    show_status
}

show_status() {
    clear
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  STATUS${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Check process
    echo -n "Checking API process... "
    if ps aux | grep -v grep | grep -q "python3.*openalgo-restart-api"; then
        echo -e "${GREEN}✅${NC}"
    else
        echo -e "${RED}❌${NC}"
    fi
    
    # Check port
    echo -n "Checking port 8888... "
    if ss -tlnp 2>/dev/null | grep -q ":8888 "; then
        echo -e "${GREEN}✅${NC}"
    else
        echo -e "${RED}❌${NC}"
    fi
    
    # Test API
    echo -n "Testing API response... "
    if curl -s -m 5 http://localhost:8888/health 2>&1 | grep -q "healthy"; then
        echo -e "${GREEN}✅${NC}"
    else
        echo -e "${RED}❌${NC}"
    fi
    
    # Get IP
    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo -e "${YELLOW}Access the dashboard:${NC}"
    echo -e "  ${GREEN}http://$SERVER_IP:8888${NC}"
    echo ""
    
    read -p "Press Enter to continue..."
    menu_main
}

show_logs() {
    clear
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  API LOGS${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo ""
    journalctl -u openalgo-restart-api -n 100 --no-pager
    echo ""
    read -p "Follow logs? (y/N): " follow
    if [[ "$follow" =~ ^[Yy]$ ]]; then
        journalctl -u openalgo-restart-api -f
    fi
    menu_main
}

# Start the menu
menu_main
