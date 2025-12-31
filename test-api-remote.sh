#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}=== OpenAlgo API Remote Connectivity Test ===${NC}\n"

# Test local connectivity first
echo -e "${YELLOW}Testing LOCAL connectivity...${NC}"
response=$(curl -s -m 3 http://localhost:8888/health 2>&1)
if echo "$response" | grep -q "healthy"; then
    echo -e "${GREEN}✅ API responds on localhost:8888${NC}"
else
    echo -e "${RED}❌ API NOT responding on localhost:8888${NC}"
    echo "Response: $response"
    exit 1
fi

# Get local IP
LOCAL_IP=$(hostname -I | awk '{print $1}')
echo -e "\n${YELLOW}Testing on LOCAL IP: $LOCAL_IP:8888${NC}"
response=$(curl -s -m 3 http://$LOCAL_IP:8888/health 2>&1)
if echo "$response" | grep -q "healthy"; then
    echo -e "${GREEN}✅ API responds on $LOCAL_IP:8888${NC}"
else
    echo -e "${RED}❌ API NOT responding on $LOCAL_IP:8888${NC}"
    echo "Response: $response"
fi

# Check port binding
echo -e "\n${YELLOW}Checking port binding...${NC}"
echo "ss -tlnp output:"
sudo ss -tlnp 2>/dev/null | grep 8888 || echo "No result from ss"

echo -e "\nnetstat -tlnp output:"
sudo netstat -tlnp 2>/dev/null | grep 8888 || echo "No result from netstat"

# Check if bound to 0.0.0.0 or 127.0.0.1
echo -e "\n${YELLOW}Analyzing binding...${NC}"
BINDING=$(sudo ss -tlnp 2>/dev/null | grep 8888 | grep -o "0\.0\.0\.0\|127\.0\.0\.1\|\[::\]" | head -1)
if [ -z "$BINDING" ]; then
    BINDING=$(sudo netstat -tlnp 2>/dev/null | grep 8888 | awk '{print $4}' | head -1)
fi

if echo "$BINDING" | grep -q "0.0.0.0\|::\|0\.0\.0\.0"; then
    echo -e "${GREEN}✅ API is bound to 0.0.0.0 (all interfaces)${NC}"
elif echo "$BINDING" | grep -q "127.0.0.1"; then
    echo -e "${RED}❌ API is bound to 127.0.0.1 (localhost only)${NC}"
    echo "This is the problem! API can only be accessed locally."
    echo ""
    echo "Fix: Update /usr/local/bin/openalgo-restart-api.py"
    echo "Change:"
    echo '  server = socketserver.TCPServer(("127.0.0.1", PORT), RestartHandler)'
    echo "To:"
    echo '  server = socketserver.TCPServer(("0.0.0.0", PORT), RestartHandler)'
    exit 1
else
    echo -e "${BLUE}ℹ️  Binding: $BINDING${NC}"
fi

# Check firewall
echo -e "\n${YELLOW}Checking firewall...${NC}"
if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    echo "UFW is active, checking port 8888..."
    if sudo ufw status | grep -q "8888"; then
        echo -e "${GREEN}✅ Port 8888 is allowed in UFW${NC}"
    else
        echo -e "${RED}❌ Port 8888 is NOT allowed in UFW${NC}"
        echo "Fix: sudo ufw allow 8888"
    fi
else
    echo -e "${BLUE}ℹ️  UFW is inactive or not installed${NC}"
fi

# Check if netstat/ss shows the port as LISTEN
echo -e "\n${YELLOW}Port status check...${NC}"
if sudo ss -tlnp 2>/dev/null | grep -q ":8888 " || sudo netstat -tlnp 2>/dev/null | grep -q ":8888 "; then
    echo -e "${GREEN}✅ Port 8888 is in LISTEN state${NC}"
else
    echo -e "${RED}❌ Port 8888 is NOT listening${NC}"
    exit 1
fi

# Check if curl can reach external interfaces
echo -e "\n${YELLOW}Testing specific network paths...${NC}"
echo "Attempting curl with verbose output (first 5 seconds):"
timeout 5 curl -v http://localhost:8888/health 2>&1 | head -20 || echo "Timeout or error"

echo -e "\n${BLUE}=== SUMMARY ===${NC}"
echo -e "✅ Local (localhost) connectivity: Working"
echo -e "✅ Port 8888 is listening: $(sudo ss -tlnp 2>/dev/null | grep -c :8888) process(es)"
echo -e "\n${YELLOW}Next step:${NC} Try from remote machine:"
echo -e "  ${GREEN}curl -v http://$(hostname -I | awk '{print $1}'):8888/health${NC}"
