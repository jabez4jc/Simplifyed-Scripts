#!/bin/bash

# ============================================================
# Manual API Test - Start API directly
# ============================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== OpenAlgo API Manual Start Test ===${NC}\n"

# Kill any existing processes
echo "Stopping any existing API processes..."
sudo pkill -9 -f "python3.*openalgo-restart-api" 2>/dev/null || true

# Also try killing by port if process still exists
if ss -tlnp 2>/dev/null | grep -q ":8888 " || netstat -tlnp 2>/dev/null | grep -q ":8888 "; then
    echo "Attempting to kill process on port 8888..."
    sudo fuser -k 8888/tcp 2>/dev/null || true
fi

sleep 2

# Check if script exists
if [ ! -f "/usr/local/bin/openalgo-restart-api.py" ]; then
    echo -e "${RED}❌ API script not found at /usr/local/bin/openalgo-restart-api.py${NC}"
    exit 1
fi

echo -e "${GREEN}✅ API script found${NC}"

# Check Python3
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}❌ Python3 not found${NC}"
    exit 1
fi

python_version=$(python3 --version 2>&1)
echo -e "${GREEN}✅ $python_version found${NC}"

# Start API in foreground to see errors
echo -e "\n${BLUE}Starting API on port 8888...${NC}\n"
sudo python3 /usr/local/bin/openalgo-restart-api.py 8888

# If script reaches here, it failed
echo -e "\n${RED}❌ API failed to start${NC}"
exit 1
