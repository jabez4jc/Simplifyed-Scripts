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

show_menu() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  OPENALGO API SETUP & MANAGEMENT${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo ""
    echo "1) Setup API as Systemd Service (Auto-start on boot)"
    echo "2) Verify API is Running and Accessible"
    echo "3) Setup Remote Restart (SSH & REST API)"
    echo "4) Setup Everything (All of the above)"
    echo "5) Manage Service (Status, Restart, Stop)"
    echo "6) View API Logs"
    echo "7) Exit"
    echo ""
    read -p "Select option [1-7]: " option
    echo ""
}

check_dependencies() {
    if [ ! -f "/usr/local/bin/openalgo-restart-api.py" ]; then
        log_message "❌ API script not found at /usr/local/bin/openalgo-restart-api.py" "$RED"
        log_message "Please run setup-remote-restart.sh first to install the API" "$YELLOW"
        exit 1
    fi
}

setup_systemd_service() {
    log_message "╔════════════════════════════════════════╗" "$BLUE"
    log_message "║ SETTING UP SYSTEMD SERVICE            ║" "$BLUE"
    log_message "╚════════════════════════════════════════╝" "$BLUE"
    
    log_message "\n📝 Creating systemd service file..." "$YELLOW"
    
    sudo tee /etc/systemd/system/openalgo-restart-api.service > /dev/null <<'EOF'
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
EOF

    if [ $? -eq 0 ]; then
        log_message "✅ Service file created" "$GREEN"
    else
        log_message "❌ Failed to create service file" "$RED"
        return 1
    fi
    
    log_message "\n🔄 Reloading systemd daemon..." "$YELLOW"
    sudo systemctl daemon-reload
    
    log_message "🛑 Stopping existing processes..." "$YELLOW"
    sudo pkill -9 -f "python3.*openalgo-restart-api" 2>/dev/null || true
    if sudo ss -tlnp 2>/dev/null | grep -q ":8888 " || sudo netstat -tlnp 2>/dev/null | grep -q ":8888 "; then
        sudo fuser -k 8888/tcp 2>/dev/null || true
    fi
    sleep 2
    
    log_message "⚙️  Enabling service..." "$YELLOW"
    sudo systemctl enable openalgo-restart-api
    
    log_message "🚀 Starting API service..." "$YELLOW"
    sudo systemctl start openalgo-restart-api
    sleep 3
    
    if sudo systemctl is-active --quiet openalgo-restart-api; then
        log_message "✅ API service is running" "$GREEN"
        return 0
    else
        log_message "❌ API service failed to start" "$RED"
        log_message "\nService logs:" "$YELLOW"
        sudo journalctl -u openalgo-restart-api -n 20
        return 1
    fi
}

verify_api() {
    log_message "╔════════════════════════════════════════╗" "$BLUE"
    log_message "║ VERIFYING API STATUS                  ║" "$BLUE"
    log_message "╚════════════════════════════════════════╝" "$BLUE"
    
    # Check if API process is running
    log_message "\n1️⃣  Checking API process..." "$YELLOW"
    if ps aux | grep -v grep | grep -q "python3.*openalgo-restart-api"; then
        log_message "✅ API process is running" "$GREEN"
    else
        log_message "❌ API process is NOT running - Starting..." "$RED"
        sudo python3 /usr/local/bin/openalgo-restart-api.py 8888 > /tmp/api.log 2>&1 &
        sleep 3
        
        if ps aux | grep -v grep | grep -q "python3.*openalgo-restart-api"; then
            log_message "✅ API process started" "$GREEN"
        else
            log_message "❌ Failed to start API" "$RED"
            return 1
        fi
    fi
    
    # Check port binding
    log_message "\n2️⃣  Checking port 8888..." "$YELLOW"
    if sudo ss -tlnp 2>/dev/null | grep -q ":8888 "; then
        log_message "✅ Port 8888 is listening" "$GREEN"
    else
        log_message "❌ Port 8888 is NOT listening" "$RED"
        return 1
    fi
    
    # Check firewall
    log_message "\n3️⃣  Checking firewall..." "$YELLOW"
    if command -v ufw &>/dev/null; then
        ufw_status=$(sudo ufw status 2>/dev/null | head -1)
        if echo "$ufw_status" | grep -q "active"; then
            if sudo ufw status | grep -q "8888"; then
                log_message "✅ Port 8888 allowed in UFW" "$GREEN"
            else
                log_message "❌ Port 8888 NOT allowed in UFW - Adding..." "$YELLOW"
                sudo ufw allow 8888/tcp
                sudo ufw allow 8888/udp
                log_message "✅ Port 8888 added to UFW" "$GREEN"
            fi
        else
            log_message "ℹ️  UFW is inactive" "$BLUE"
        fi
    fi
    
    # Test API
    log_message "\n4️⃣  Testing API connectivity..." "$YELLOW"
    response=$(curl -s -m 5 http://localhost:8888/health 2>&1)
    
    if echo "$response" | grep -q "healthy"; then
        log_message "✅ API is responding" "$GREEN"
    else
        log_message "❌ API not responding" "$RED"
        return 1
    fi
    
    # Server info
    SERVER_IP=$(hostname -I | awk '{print $1}')
    log_message "\n5️⃣  Server Information" "$YELLOW"
    log_message "   Local IP: $SERVER_IP" "$BLUE"
    log_message "   API URL: http://$SERVER_IP:8888" "$BLUE"
    
    # Summary
    log_message "\n╔════════════════════════════════════════╗" "$GREEN"
    log_message "║ ✅ API VERIFICATION COMPLETE          ║" "$GREEN"
    log_message "╚════════════════════════════════════════╝" "$GREEN"
    log_message "\nAccess from remote:" "$YELLOW"
    log_message "  http://$SERVER_IP:8888" "$GREEN"
    log_message "  http://$SERVER_IP:8888/health" "$GREEN"
    log_message "  http://$SERVER_IP:8888/api/instances" "$GREEN"
    
    return 0
}

setup_remote_restart() {
    log_message "╔════════════════════════════════════════╗" "$BLUE"
    log_message "║ SETUP REMOTE RESTART OPTIONS          ║" "$BLUE"
    log_message "╚════════════════════════════════════════╝" "$BLUE"
    
    log_message "\n📋 OPTIONS FOR REMOTE RESTART:" "$BLUE"
    echo ""
    echo "1) SSH Command (Direct remote execution)"
    echo "2) REST API Endpoint (HTTP webhook)"
    echo "3) Setup both options"
    echo ""
    
    read -p "Select option [1-3]: " remote_option
    
    case $remote_option in
        1|3)
            setup_ssh_restart
            ;;
    esac
    
    case $remote_option in
        2|3)
            setup_api_endpoints
            ;;
    esac
}

setup_ssh_restart() {
    log_message "\n${YELLOW}SSH REMOTE RESTART SETUP${NC}" "$BLUE"
    
    SERVER_IP=$(hostname -I | awk '{print $1}')
    log_message "\n📋 You can now trigger restarts via SSH:" "$BLUE"
    log_message "\nFrom remote machine:" "$YELLOW"
    log_message "  ssh root@$SERVER_IP sudo /usr/local/bin/openalgo-daily-restart.sh" "$GREEN"
    log_message "  ssh root@$SERVER_IP sudo systemctl restart openalgo*" "$GREEN"
    log_message "\nView logs:" "$YELLOW"
    log_message "  ssh root@$SERVER_IP tail -f /var/log/openalgo-daily-restart.log" "$GREEN"
}

setup_api_endpoints() {
    log_message "\n${YELLOW}REST API ENDPOINTS${NC}" "$BLUE"
    
    SERVER_IP=$(hostname -I | awk '{print $1}')
    log_message "\n📋 REST API is available at:" "$BLUE"
    log_message "\nWeb UI (Recommended):" "$YELLOW"
    log_message "  http://$SERVER_IP:8888" "$GREEN"
    
    log_message "\nREST Endpoints:" "$YELLOW"
    log_message "  GET  http://$SERVER_IP:8888/health - Health check" "$GREEN"
    log_message "  GET  http://$SERVER_IP:8888/api/instances - List instances" "$GREEN"
    log_message "  GET  http://$SERVER_IP:8888/api/status - Get status" "$GREEN"
    log_message "  POST http://$SERVER_IP:8888/api/restart-all - Restart all" "$GREEN"
    log_message "  POST http://$SERVER_IP:8888/api/restart-instance - Restart one" "$GREEN"
    
    log_message "\n📝 Example curl commands:" "$YELLOW"
    log_message "  curl http://$SERVER_IP:8888/health" "$GREEN"
    log_message "  curl http://$SERVER_IP:8888/api/instances" "$GREEN"
    log_message '  curl -X POST http://$SERVER_IP:8888/api/restart-all' "$GREEN"
}

manage_service() {
    log_message "\n╔════════════════════════════════════════╗" "$BLUE"
    log_message "║ SERVICE MANAGEMENT                    ║" "$BLUE"
    log_message "╚════════════════════════════════════════╝" "$BLUE"
    
    echo ""
    echo "1) Check status"
    echo "2) Restart service"
    echo "3) Stop service"
    echo "4) Start service"
    echo "5) View detailed logs"
    echo ""
    read -p "Select option [1-5]: " mgmt_option
    
    case $mgmt_option in
        1)
            log_message "\n📊 Service Status:" "$YELLOW"
            sudo systemctl status openalgo-restart-api
            ;;
        2)
            log_message "\n🔄 Restarting service..." "$YELLOW"
            sudo systemctl restart openalgo-restart-api
            sleep 2
            sudo systemctl status openalgo-restart-api --no-pager
            ;;
        3)
            log_message "\n🛑 Stopping service..." "$YELLOW"
            sudo systemctl stop openalgo-restart-api
            log_message "✅ Service stopped" "$GREEN"
            ;;
        4)
            log_message "\n🚀 Starting service..." "$YELLOW"
            sudo systemctl start openalgo-restart-api
            sleep 2
            sudo systemctl status openalgo-restart-api --no-pager
            ;;
        5)
            log_message "\n📋 API Logs (last 50 lines):" "$YELLOW"
            sudo journalctl -u openalgo-restart-api -n 50
            ;;
        *)
            log_message "Invalid option" "$RED"
            ;;
    esac
}

view_logs() {
    log_message "\n╔════════════════════════════════════════╗" "$BLUE"
    log_message "║ API LOGS                              ║" "$BLUE"
    log_message "╚════════════════════════════════════════╝" "$BLUE"
    
    echo ""
    echo "1) Last 20 lines"
    echo "2) Last 50 lines"
    echo "3) Last 100 lines"
    echo "4) Follow logs (live)"
    echo "5) Back to menu"
    echo ""
    read -p "Select option [1-5]: " log_option
    
    case $log_option in
        1)
            sudo journalctl -u openalgo-restart-api -n 20 --no-pager
            ;;
        2)
            sudo journalctl -u openalgo-restart-api -n 50 --no-pager
            ;;
        3)
            sudo journalctl -u openalgo-restart-api -n 100 --no-pager
            ;;
        4)
            log_message "Following logs (press Ctrl+C to exit)..." "$YELLOW"
            sudo journalctl -u openalgo-restart-api -f
            ;;
        5)
            return
            ;;
        *)
            log_message "Invalid option" "$RED"
            ;;
    esac
}

main() {
    show_banner
    check_dependencies
    
    while true; do
        show_menu
        
        case $option in
            1)
                setup_systemd_service
                read -p "Press Enter to continue..."
                ;;
            2)
                verify_api
                read -p "Press Enter to continue..."
                ;;
            3)
                setup_remote_restart
                read -p "Press Enter to continue..."
                ;;
            4)
                setup_systemd_service
                verify_api
                setup_remote_restart
                read -p "Press Enter to continue..."
                ;;
            5)
                manage_service
                read -p "Press Enter to continue..."
                ;;
            6)
                view_logs
                read -p "Press Enter to continue..."
                ;;
            7)
                log_message "\nGoodbye! 👋" "$BLUE"
                exit 0
                ;;
            *)
                log_message "Invalid option. Please try again." "$RED"
                read -p "Press Enter to continue..."
                ;;
        esac
        
        clear
        show_banner
    done
}

main
