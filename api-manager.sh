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
    echo "1) Install & Setup API"
    echo "2) Verify API Status"
    echo "3) Manage Service"
    echo "4) View Logs"
    echo "5) Exit"
    echo ""
    read -p "Select option [1-5]: " choice
    echo ""
    
    case $choice in
        1) menu_setup ;;
        2) verify_api ;;
        3) menu_manage ;;
        4) menu_logs ;;
        5) exit 0 ;;
        *) echo "Invalid option"; sleep 2; menu_main ;;
    esac
}

menu_setup() {
    clear
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  SETUP & CONFIGURATION${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo ""
    echo "1) Install API (copies openalgo-restart-api.py to /usr/local/bin/)"
    echo "2) Setup Systemd Service (auto-start on boot)"
    echo "3) Configure Firewall"
    echo "4) Setup Everything (All of the above)"
    echo "5) Back to Menu"
    echo ""
    read -p "Select option [1-5]: " choice
    echo ""
    
    case $choice in
        1) install_api; read -p "Press Enter to continue..."; menu_main ;;
        2) setup_service; read -p "Press Enter to continue..."; menu_main ;;
        3) setup_firewall; read -p "Press Enter to continue..."; menu_main ;;
        4) install_api && echo "" && setup_service && echo "" && setup_firewall; read -p "Press Enter to continue..."; menu_main ;;
        5) menu_main ;;
        *) echo "Invalid option"; sleep 2; menu_setup ;;
    esac
}

menu_manage() {
    clear
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  SERVICE MANAGEMENT${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo ""
    echo "1) Check Service Status"
    echo "2) Start Service"
    echo "3) Stop Service"
    echo "4) Restart Service"
    echo "5) Back to Menu"
    echo ""
    read -p "Select option [1-5]: " choice
    echo ""
    
    case $choice in
        1) systemctl status openalgo-restart-api; read -p "Press Enter to continue..."; menu_main ;;
        2) systemctl start openalgo-restart-api; echo -e "${GREEN}✅ Started${NC}"; sleep 1; menu_main ;;
        3) systemctl stop openalgo-restart-api; echo -e "${GREEN}✅ Stopped${NC}"; sleep 1; menu_main ;;
        4) systemctl restart openalgo-restart-api; echo -e "${GREEN}✅ Restarted${NC}"; sleep 1; menu_main ;;
        5) menu_main ;;
        *) echo "Invalid option"; sleep 2; menu_manage ;;
    esac
}

menu_logs() {
    clear
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  API LOGS${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo ""
    echo "1) Last 20 lines"
    echo "2) Last 50 lines"
    echo "3) Last 100 lines"
    echo "4) Follow logs (press Ctrl+C to exit)"
    echo "5) Back to Menu"
    echo ""
    read -p "Select option [1-5]: " choice
    
    case $choice in
        1) journalctl -u openalgo-restart-api -n 20 --no-pager; read -p "Press Enter..."; menu_main ;;
        2) journalctl -u openalgo-restart-api -n 50 --no-pager; read -p "Press Enter..."; menu_main ;;
        3) journalctl -u openalgo-restart-api -n 100 --no-pager; read -p "Press Enter..."; menu_main ;;
        4) journalctl -u openalgo-restart-api -f ;;
        5) menu_main ;;
        *) echo "Invalid option"; sleep 2; menu_logs ;;
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
    
    # Kill any existing processes
    pkill -9 -f "python3.*openalgo-restart-api" 2>/dev/null || true
    fuser -k 8888/tcp 2>/dev/null || true
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

verify_api() {
    clear
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  API VERIFICATION${NC}"
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

# Start the menu
menu_main
