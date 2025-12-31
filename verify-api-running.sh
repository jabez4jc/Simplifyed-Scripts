#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}=== OpenAlgo API Status Verification ===${NC}\n"

# Check if API process is running
echo -e "${YELLOW}1. Checking if API process is running...${NC}"
if ps aux | grep -v grep | grep -q "python3.*openalgo-restart-api"; then
    echo -e "${GREEN}✅ API process is running${NC}"
    ps aux | grep -v grep | grep "python3.*openalgo-restart-api"
else
    echo -e "${RED}❌ API process is NOT running${NC}"
    echo -e "\n${YELLOW}Starting API now...${NC}"
    sudo python3 /usr/local/bin/openalgo-restart-api.py 8888 > /tmp/api.log 2>&1 &
    sleep 3
    
    if ps aux | grep -v grep | grep -q "python3.*openalgo-restart-api"; then
        echo -e "${GREEN}✅ API process started successfully${NC}"
    else
        echo -e "${RED}❌ Failed to start API process${NC}"
        echo "Error log:"
        cat /tmp/api.log
        exit 1
    fi
fi

# Check port binding
echo -e "\n${YELLOW}2. Checking port 8888 binding...${NC}"
if sudo ss -tlnp 2>/dev/null | grep -q ":8888 "; then
    echo -e "${GREEN}✅ Port 8888 is listening${NC}"
    sudo ss -tlnp 2>/dev/null | grep ":8888"
else
    echo -e "${RED}❌ Port 8888 is NOT listening${NC}"
    exit 1
fi

# Check firewall (UFW)
echo -e "\n${YELLOW}3. Checking firewall rules...${NC}"
if command -v ufw &>/dev/null; then
    ufw_status=$(sudo ufw status 2>/dev/null | head -1)
    echo "UFW Status: $ufw_status"
    
    if echo "$ufw_status" | grep -q "active"; then
        if sudo ufw status | grep -q "8888"; then
            echo -e "${GREEN}✅ Port 8888 allowed in UFW${NC}"
        else
            echo -e "${RED}❌ Port 8888 NOT allowed in UFW${NC}"
            echo "Adding port to UFW..."
            sudo ufw allow 8888/tcp
            echo -e "${GREEN}✅ Port 8888 added to UFW${NC}"
        fi
    fi
else
    echo -e "${BLUE}ℹ️  UFW not installed${NC}"
fi

# Test API locally
echo -e "\n${YELLOW}4. Testing API connectivity...${NC}"
response=$(curl -s -m 5 http://localhost:8888/health 2>&1)

if echo "$response" | grep -q "healthy"; then
    echo -e "${GREEN}✅ API responds to localhost requests${NC}"
    echo "Response: $response"
else
    echo -e "${RED}❌ API not responding${NC}"
    echo "Response: $response"
    exit 1
fi

# Get server info
echo -e "\n${YELLOW}5. Server Information...${NC}"
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "Local IP: $SERVER_IP"
echo "API URL: http://$SERVER_IP:8888"

# Test from external (if available)
echo -e "\n${YELLOW}6. Testing from remote (this may take a moment)...${NC}"
timeout 10 curl -s -m 5 http://localhost:8888/api/instances > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ API responds to /api/instances endpoint${NC}"
else
    echo -e "${YELLOW}⚠️  /api/instances endpoint not responding (may be normal if no instances)${NC}"
fi

# Summary
echo -e "\n${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}✅ API VERIFICATION COMPLETE${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo -e "\n${YELLOW}Access the API from remote:${NC}"
echo -e "  ${GREEN}http://$SERVER_IP:8888${NC}"
echo -e "  ${GREEN}http://$SERVER_IP:8888/health${NC}"
echo -e "  ${GREEN}http://$SERVER_IP:8888/api/instances${NC}"
echo -e "\n${YELLOW}If still not accessible from remote:${NC}"
echo -e "  1. Check GCP Firewall: VPC Network > Firewall rules"
echo -e "  2. Ensure rule allows TCP:8888 from your source IP"
echo -e "  3. Wait 1-2 minutes for firewall rule to propagate"
echo -e "  4. Try: ${GREEN}curl -v http://$SERVER_IP:8888/health${NC}"
