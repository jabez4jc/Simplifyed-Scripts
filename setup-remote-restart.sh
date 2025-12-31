#!/bin/bash

# ============================================================
# Setup Remote Restart Trigger via SSH
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
echo "              SETUP REMOTE RESTART TRIGGER                            "
echo -e "${NC}"

log_message "\n📋 OPTIONS FOR REMOTE RESTART:" "$BLUE"
echo ""
echo "1) SSH Command (Direct remote execution)"
echo "2) REST API Endpoint (HTTP webhook)"
echo "3) Setup both options"
echo ""

read -p "Select option [1-3]: " option

case $option in
    1|3)
        # SSH Setup
        log_message "\n╔════════════════════════════════════╗" "$BLUE"
        log_message "║ SSH REMOTE RESTART SETUP            ║" "$BLUE"
        log_message "╚════════════════════════════════════╝" "$BLUE"
        
        log_message "\n📋 SSH allows you to trigger restart from any machine with SSH access" "$BLUE"
        log_message "\n🔧 Setting up SSH command..." "$BLUE"
        
        # Create SSH wrapper script
        RESTART_SCRIPT="/usr/local/bin/openalgo-daily-restart.sh"
        SSH_WRAPPER="/usr/local/bin/restart-openalgo-ssh"
        
        cat > "$SSH_WRAPPER" << 'EOF'
#!/bin/bash
# SSH wrapper for remote restart
sudo /usr/local/bin/openalgo-daily-restart.sh
EOF
        
        sudo chmod +x "$SSH_WRAPPER"
        
        log_message "✅ SSH wrapper created at $SSH_WRAPPER" "$GREEN"
        
        # Get server IP
        SERVER_IP=$(hostname -I | awk '{print $1}')
        SERVER_HOSTNAME=$(hostname)
        
        log_message "\n📞 REMOTE SSH COMMAND:" "$YELLOW"
        log_message "   From any machine with SSH access, run:" "$BLUE"
        echo ""
        log_message "   ssh root@$SERVER_IP sudo /usr/local/bin/openalgo-daily-restart.sh" "$GREEN"
        echo ""
        log_message "   Or using hostname:" "$BLUE"
        echo ""
        log_message "   ssh root@$SERVER_HOSTNAME sudo /usr/local/bin/openalgo-daily-restart.sh" "$GREEN"
        echo ""
        
        log_message "⚠️  PREREQUISITES FOR SSH:" "$YELLOW"
        log_message "   • SSH key authentication configured" "$BLUE"
        log_message "   • SSH access to root user enabled" "$BLUE"
        log_message "   • SSH port open on firewall (default: 22)" "$BLUE"
        ;;
esac

case $option in
    2|3)
        # REST API Setup
        log_message "\n╔════════════════════════════════════╗" "$BLUE"
        log_message "║ REST API WEBHOOK SETUP              ║" "$BLUE"
        log_message "╚════════════════════════════════════╝" "$BLUE"
        
        log_message "\n📋 REST API allows HTTP requests to trigger restart" "$BLUE"
        log_message "\n🔧 Setting up REST API endpoint..." "$BLUE"
        
        # Create systemd socket and service for API
        API_PORT=${1:-8888}
        
        read -p "Enter API port [default: 8888]: " port_input
        if [ ! -z "$port_input" ]; then
            API_PORT="$port_input"
        fi
        
        # Copy enhanced REST API script
        SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
        SOURCE_API="$SCRIPT_DIR/openalgo-restart-api-enhanced.py"
        API_SCRIPT="/usr/local/bin/openalgo-restart-api.py"
        
        if [ -f "$SOURCE_API" ]; then
            log_message "   Copying enhanced API from repository..." "$BLUE"
            sudo cp "$SOURCE_API" "$API_SCRIPT"
            sudo chmod +x "$API_SCRIPT"
        else
            log_message "   Creating basic API script..." "$BLUE"
            cat > "$API_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
import http.server
import socketserver
import subprocess
import json
import sys
from threading import Thread

class RestartHandler(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        if self.path == '/restart':
            # Run restart script in background
            Thread(target=self.trigger_restart).start()
            
            # Send response immediately
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            response = json.dumps({
                "status": "success",
                "message": "Restart triggered for all OpenAlgo instances",
                "timestamp": str(__import__('datetime').datetime.now())
            }).encode()
            self.wfile.write(response)
        else:
            self.send_response(404)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            response = json.dumps({
                "status": "error",
                "message": "Endpoint not found. Use POST /restart"
            }).encode()
            self.wfile.write(response)
    
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            response = json.dumps({
                "status": "healthy",
                "service": "OpenAlgo Restart API",
                "timestamp": str(__import__('datetime').datetime.now())
            }).encode()
            self.wfile.write(response)
        elif self.path == '/status':
            # Get instance status
            status = self.get_instance_status()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            response = json.dumps(status).encode()
            self.wfile.write(response)
        else:
            self.send_response(404)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            response = json.dumps({
                "status": "error",
                "message": "Endpoints: POST /restart, GET /health, GET /status"
            }).encode()
            self.wfile.write(response)
    
    def get_instance_status(self):
        """Get status of all instances"""
        try:
            result = subprocess.run(
                ['bash', '-c', 'ls -1 /var/python/openalgo-flask | grep openalgo'],
                capture_output=True, text=True, timeout=5
            )
            instances = result.stdout.strip().split('\n') if result.stdout.strip() else []
            
            status_info = {
                "total_instances": len(instances),
                "instances": {}
            }
            
            for inst in instances:
                if inst:
                    status_result = subprocess.run(
                        ['systemctl', 'is-active', inst],
                        capture_output=True, text=True, timeout=2
                    )
                    status_info["instances"][inst] = status_result.stdout.strip()
            
            status_info["timestamp"] = str(__import__('datetime').datetime.now())
            return status_info
        except Exception as e:
            return {"error": str(e), "timestamp": str(__import__('datetime').datetime.now())}
    
    def trigger_restart(self):
        """Trigger restart in background"""
        try:
            subprocess.run(['/usr/local/bin/openalgo-daily-restart.sh'], 
                          check=True, capture_output=True)
        except Exception as e:
            print(f"Error triggering restart: {e}", file=sys.stderr)
    
    def log_message(self, format, *args):
        """Suppress default logging"""
        pass

def run_api(port):
    handler = RestartHandler
    with socketserver.TCPServer(("", port), handler) as httpd:
        print(f"OpenAlgo Restart API listening on port {port}")
        sys.stdout.flush()
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("API server stopped")

if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8888
    run_api(port)
PYEOF
        fi
        
        sudo chmod +x "$API_SCRIPT"
        
        # Create systemd service for API
        API_SERVICE="/etc/systemd/system/openalgo-restart-api.service"
        
        cat > "$API_SERVICE" << EOF
[Unit]
Description=OpenAlgo Remote Restart API
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/tmp
ExecStart=/usr/bin/python3 /usr/local/bin/openalgo-restart-api.py $API_PORT
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
        
        sudo systemctl daemon-reload
        sudo systemctl enable openalgo-restart-api > /dev/null 2>&1
        sudo systemctl start openalgo-restart-api > /dev/null 2>&1
        
        if systemctl is-active --quiet openalgo-restart-api; then
            log_message "✅ REST API service started on port $API_PORT" "$GREEN"
        else
            log_message "⚠️  REST API service may not have started" "$YELLOW"
        fi
        
        # Get server IP
        SERVER_IP=$(hostname -I | awk '{print $1}')
        SERVER_HOSTNAME=$(hostname)
        
        log_message "\n📞 REMOTE API COMMANDS:" "$YELLOW"
        log_message "\n   Using curl:" "$BLUE"
        echo ""
        log_message "   curl -X POST http://$SERVER_IP:$API_PORT/restart" "$GREEN"
        echo ""
        log_message "   Using wget:" "$BLUE"
        echo ""
        log_message "   wget -O- http://$SERVER_IP:$API_PORT/restart" "$GREEN"
        echo ""
        log_message "   Using Python:" "$BLUE"
        echo ""
        log_message "   python3 -c \"import requests; requests.post('http://$SERVER_IP:$API_PORT/restart')\"" "$GREEN"
        echo ""
        
        log_message "⚠️  PREREQUISITES FOR API:" "$YELLOW"
        log_message "   • Port $API_PORT open on firewall" "$BLUE"
        log_message "   • curl, wget, or Python installed on remote machine" "$BLUE"
        log_message "   • Network access from remote to server" "$BLUE"
        ;;
esac

# Additional option: Create monitoring script
log_message "\n╔════════════════════════════════════╗" "$BLUE"
log_message "║ ADDITIONAL FEATURES                 ║" "$BLUE"
log_message "╚════════════════════════════════════╝" "$BLUE"

log_message "\n📋 VIEW RESTART LOGS REMOTELY:" "$YELLOW"
log_message "   Via SSH:" "$BLUE"
echo ""
log_message "   ssh root@$SERVER_IP tail -f /var/log/openalgo-daily-restart.log" "$GREEN"
echo ""

log_message "📋 CHECK RESTART STATUS:" "$YELLOW"
log_message "   Via SSH:" "$BLUE"
echo ""
log_message "   ssh root@$SERVER_IP systemctl status openalgo*" "$GREEN"
echo ""

log_message "📋 SCHEDULE REMOTE RESTART:" "$YELLOW"
log_message "   Using at command (one-time):" "$BLUE"
echo ""
log_message "   ssh root@$SERVER_IP \"echo '/usr/local/bin/openalgo-daily-restart.sh' | at now + 5 minutes\"" "$GREEN"
echo ""

# Create a convenience script
log_message "\n🔧 Creating convenience scripts..." "$BLUE"

# Remote restart convenience script
REMOTE_RESTART="/usr/local/bin/restart-openalgo-remote"

cat > "$REMOTE_RESTART" << 'EOF'
#!/bin/bash

# OpenAlgo Remote Restart Convenience Script

if [ $# -lt 1 ]; then
    echo "Usage: $0 <server_ip_or_hostname> [command]"
    echo ""
    echo "Examples:"
    echo "  $0 192.168.1.100              # Trigger restart"
    echo "  $0 server.example.com status  # Check status"
    echo "  $0 server.example.com logs    # View logs"
    echo "  $0 server.example.com list    # List all instances"
    exit 1
fi

SERVER="$1"
CMD="${2:-restart}"

case $CMD in
    restart)
        echo "Triggering restart on $SERVER..."
        ssh root@$SERVER sudo /usr/local/bin/openalgo-daily-restart.sh
        ;;
    status)
        echo "Checking status on $SERVER..."
        ssh root@$SERVER "systemctl status openalgo* | grep -E '(openalgo|Active)'"
        ;;
    logs)
        echo "Viewing logs on $SERVER..."
        ssh root@$SERVER tail -f /var/log/openalgo-daily-restart.log
        ;;
    list)
        echo "Listing instances on $SERVER..."
        ssh root@$SERVER "ls -1 /var/python/openalgo-flask | grep openalgo"
        ;;
    *)
        echo "Unknown command: $CMD"
        echo "Valid commands: restart, status, logs, list"
        exit 1
        ;;
esac
EOF

sudo chmod +x "$REMOTE_RESTART"
log_message "✅ Created convenience script: $REMOTE_RESTART" "$GREEN"

log_message "\n📚 USAGE:" "$YELLOW"
log_message "   Trigger restart:" "$BLUE"
log_message "   $REMOTE_RESTART <server> restart" "$GREEN"
echo ""
log_message "   Check status:" "$BLUE"
log_message "   $REMOTE_RESTART <server> status" "$GREEN"
echo ""
log_message "   View logs:" "$BLUE"
log_message "   $REMOTE_RESTART <server> logs" "$GREEN"
echo ""

# Summary
log_message "\n╔════════════════════════════════════════════════════════╗" "$GREEN"
log_message "║      REMOTE RESTART SETUP COMPLETED                   ║" "$GREEN"
log_message "╚════════════════════════════════════════════════════════╝" "$GREEN"

log_message "\n✅ Remote restart methods are now available:" "$GREEN"
log_message "   • SSH: Direct command execution" "$BLUE"
log_message "   • API: HTTP webhook endpoint (if enabled)" "$BLUE"
log_message "   • Convenience script: Easy management tool" "$BLUE"

log_message "\n💡 SECURITY NOTES:" "$YELLOW"
log_message "   • Use SSH keys instead of passwords" "$BLUE"
log_message "   • Restrict SSH access in firewall" "$BLUE"
log_message "   • Monitor logs for unauthorized access" "$BLUE"
log_message "   • Consider using VPN for remote access" "$BLUE"
