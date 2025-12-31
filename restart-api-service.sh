#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}=== OpenAlgo API Service Restart ===${NC}\n"

# Step 1: Kill existing processes
echo -e "${YELLOW}Step 1: Stopping existing API processes...${NC}"
sudo pkill -9 -f "python3.*openalgo-restart-api" 2>/dev/null && echo "Killed via pkill" || echo "No process found via pkill"

# Step 2: Kill by port (multiple methods)
echo -e "${YELLOW}Step 2: Clearing port 8888...${NC}"

# Try fuser first (most reliable for port-based killing)
if command -v fuser &>/dev/null; then
    sudo fuser -k 8888/tcp 2>/dev/null && echo "Killed via fuser" || echo "No process on port 8888 (fuser)"
fi

# Try ss if fuser didn't work
if ss -tlnp 2>/dev/null | grep -q ":8888 "; then
    PID=$(ss -tlnp 2>/dev/null | grep ":8888 " | awk '{print $NF}' | cut -d'/' -f1 | head -1)
    if [ ! -z "$PID" ]; then
        sudo kill -9 "$PID" 2>/dev/null && echo "Killed PID $PID via ss" || echo "Failed to kill PID $PID"
    fi
fi

# Try netstat if ss didn't work
if netstat -tlnp 2>/dev/null | grep -q ":8888 "; then
    PID=$(netstat -tlnp 2>/dev/null | grep ":8888 " | awk '{print $NF}' | cut -d'/' -f1 | head -1)
    if [ ! -z "$PID" ]; then
        sudo kill -9 "$PID" 2>/dev/null && echo "Killed PID $PID via netstat" || echo "Failed to kill PID $PID"
    fi
fi

sleep 2

# Step 3: Verify port is free
echo -e "${YELLOW}Step 3: Verifying port 8888 is free...${NC}"
if ss -tlnp 2>/dev/null | grep -q ":8888 " || netstat -tlnp 2>/dev/null | grep -q ":8888 "; then
    echo -e "${RED}❌ Port 8888 is still in use!${NC}"
    echo "Port status:"
    ss -tlnp 2>/dev/null | grep 8888 || netstat -tlnp 2>/dev/null | grep 8888
    exit 1
else
    echo -e "${GREEN}✅ Port 8888 is free${NC}"
fi

# Step 4: Start the API service
echo -e "${YELLOW}Step 4: Starting API service...${NC}"

if [ ! -f "/usr/local/bin/openalgo-restart-api.py" ]; then
    echo -e "${RED}❌ API script not found at /usr/local/bin/openalgo-restart-api.py${NC}"
    exit 1
fi

sudo python3 /usr/local/bin/openalgo-restart-api.py 8888 > /tmp/api.log 2>&1 &
API_PID=$!
sleep 3

# Step 5: Verify API is running
echo -e "${YELLOW}Step 5: Verifying API is running...${NC}"

if ps -p $API_PID > /dev/null; then
    echo -e "${GREEN}✅ API process started (PID: $API_PID)${NC}"
else
    echo -e "${RED}❌ API process failed to start${NC}"
    echo "Error log:"
    cat /tmp/api.log
    exit 1
fi

# Step 6: Test connectivity
echo -e "${YELLOW}Step 6: Testing API connectivity...${NC}"

response=$(curl -s -m 5 http://localhost:8888/health 2>&1)
if echo "$response" | grep -q "healthy"; then
    echo -e "${GREEN}✅ API is responding${NC}"
    echo "Response: $response"
else
    echo -e "${RED}❌ API not responding or invalid response${NC}"
    echo "Response: $response"
    exit 1
fi

echo -e "\n${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}✅ API SERVICE RESTARTED SUCCESSFULLY${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo -e "\nAccess the API at: ${GREEN}http://localhost:8888${NC}"
echo -e "Web UI: ${GREEN}http://localhost:8888/${NC}"
echo -e "Health check: ${GREEN}curl http://localhost:8888/health${NC}\n"
