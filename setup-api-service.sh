#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}=== OpenAlgo API Service Setup ===${NC}\n"

# Check if API script exists
if [ ! -f "/usr/local/bin/openalgo-restart-api.py" ]; then
    echo -e "${RED}❌ API script not found at /usr/local/bin/openalgo-restart-api.py${NC}"
    echo "Please run setup-remote-restart.sh first"
    exit 1
fi

echo -e "${GREEN}✅ API script found${NC}\n"

# Create systemd service file
echo -e "${YELLOW}Creating systemd service file...${NC}"

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
    echo -e "${GREEN}✅ Service file created${NC}"
else
    echo -e "${RED}❌ Failed to create service file${NC}"
    exit 1
fi

# Reload systemd
echo -e "\n${YELLOW}Reloading systemd daemon...${NC}"
sudo systemctl daemon-reload

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Systemd reloaded${NC}"
else
    echo -e "${RED}❌ Failed to reload systemd${NC}"
    exit 1
fi

# Kill any existing API processes
echo -e "\n${YELLOW}Stopping existing API processes...${NC}"
sudo pkill -9 -f "python3.*openalgo-restart-api" 2>/dev/null || true

# Kill by port if still running
if sudo ss -tlnp 2>/dev/null | grep -q ":8888 " || sudo netstat -tlnp 2>/dev/null | grep -q ":8888 "; then
    sudo fuser -k 8888/tcp 2>/dev/null || true
fi

sleep 2

# Enable service
echo -e "${YELLOW}Enabling service to start on boot...${NC}"
sudo systemctl enable openalgo-restart-api

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Service enabled${NC}"
else
    echo -e "${RED}❌ Failed to enable service${NC}"
    exit 1
fi

# Start service
echo -e "\n${YELLOW}Starting API service...${NC}"
sudo systemctl start openalgo-restart-api

sleep 3

# Check status
echo -e "\n${YELLOW}Checking service status...${NC}"
if sudo systemctl is-active --quiet openalgo-restart-api; then
    echo -e "${GREEN}✅ API service is running${NC}"
else
    echo -e "${RED}❌ API service failed to start${NC}"
    echo -e "\n${YELLOW}Service logs:${NC}"
    sudo journalctl -u openalgo-restart-api -n 20
    exit 1
fi

# Verify port is listening
echo -e "\n${YELLOW}Verifying port 8888 is listening...${NC}"
if sudo ss -tlnp 2>/dev/null | grep -q ":8888 "; then
    echo -e "${GREEN}✅ Port 8888 is listening${NC}"
else
    echo -e "${RED}❌ Port 8888 is NOT listening${NC}"
    exit 1
fi

# Test API
echo -e "\n${YELLOW}Testing API connectivity...${NC}"
response=$(curl -s -m 5 http://localhost:8888/health 2>&1)

if echo "$response" | grep -q "healthy"; then
    echo -e "${GREEN}✅ API is responding${NC}"
    echo "Response: $response"
else
    echo -e "${RED}❌ API not responding${NC}"
    echo "Response: $response"
    exit 1
fi

# Get server IP
SERVER_IP=$(hostname -I | awk '{print $1}')

echo -e "\n${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}✅ API SERVICE SETUP COMPLETE${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo -e "\n${YELLOW}Service Management:${NC}"
echo -e "  Check status:    ${GREEN}sudo systemctl status openalgo-restart-api${NC}"
echo -e "  View logs:       ${GREEN}sudo journalctl -u openalgo-restart-api -f${NC}"
echo -e "  Stop service:    ${GREEN}sudo systemctl stop openalgo-restart-api${NC}"
echo -e "  Restart service: ${GREEN}sudo systemctl restart openalgo-restart-api${NC}"
echo -e "\n${YELLOW}Test the API:${NC}"
echo -e "  Health check:    ${GREEN}curl http://localhost:8888/health${NC}"
echo -e "  Instances list:  ${GREEN}curl http://localhost:8888/api/instances${NC}"
echo -e "  Web UI:          ${GREEN}http://$SERVER_IP:8888${NC}"
echo -e "\n${YELLOW}API will automatically:${NC}"
echo -e "  ✅ Start on server boot"
echo -e "  ✅ Restart if it crashes"
echo -e "  ✅ Log all activity to systemd journal"
