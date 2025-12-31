#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}=== OpenAlgo Server Configuration Comparison ===${NC}\n"

# Working server
WORKING_IP="34.14.188.9"

# Failing servers
FAILING_IPS=(
    "34.14.189.59"
    "34.100.234.16"
    "4.240.82.132"
    "34.47.174.225"
    "34.47.166.129"
    "34.93.253.215"
)

# Collect diagnostic info
echo -e "${YELLOW}Collecting diagnostic information...${NC}\n"

collect_server_info() {
    local ip=$1
    local label=$2
    
    echo -e "${BLUE}=== $label ($ip) ===${NC}"
    
    # API availability
    echo -n "API Access (localhost): "
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$ip "curl -s http://localhost:8888/health" 2>/dev/null | grep -q "healthy"; then
        echo -e "${GREEN}✅${NC}"
    else
        echo -e "${RED}❌${NC}"
    fi
    
    # Port binding
    echo -n "Port 8888 Binding: "
    binding=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$ip "sudo ss -tlnp 2>/dev/null | grep 8888 | grep -o '0\.0\.0\.0\|127\.0\.0\.1\|::\*'" 2>/dev/null | head -1)
    if [ -z "$binding" ]; then
        binding=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$ip "sudo netstat -tlnp 2>/dev/null | grep 8888 | awk '{print \$4}'" 2>/dev/null | head -1)
    fi
    
    if echo "$binding" | grep -q "0.0.0.0\|::"; then
        echo -e "${GREEN}0.0.0.0${NC} (All interfaces)"
    elif echo "$binding" | grep -q "127.0.0.1"; then
        echo -e "${RED}127.0.0.1${NC} (Localhost only)"
    else
        echo "Unknown: $binding"
    fi
    
    # UFW Status
    echo -n "UFW Firewall: "
    ufw_status=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$ip "sudo ufw status 2>/dev/null | head -1" 2>/dev/null)
    echo "$ufw_status"
    
    # Port 8888 in UFW
    echo -n "Port 8888 in UFW: "
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$ip "sudo ufw status | grep -q 8888" 2>/dev/null; then
        echo -e "${GREEN}✅${NC}"
    else
        echo -e "${RED}❌${NC}"
    fi
    
    # Python process
    echo -n "API Process Running: "
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$ip "ps aux | grep -v grep | grep -q 'python3.*openalgo-restart-api'" 2>/dev/null; then
        echo -e "${GREEN}✅${NC}"
    else
        echo -e "${RED}❌${NC}"
    fi
    
    # Check if port is listening
    echo -n "Port 8888 Listening: "
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$ip "sudo ss -tlnp 2>/dev/null | grep -q :8888" 2>/dev/null; then
        echo -e "${GREEN}✅${NC}"
    else
        echo -e "${RED}❌${NC}"
    fi
    
    # Cloud provider detection
    echo -n "Cloud Provider: "
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$ip "curl -s -m 1 -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/ 2>/dev/null" 2>/dev/null | grep -q .; then
        echo "GCP"
    elif ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$ip "curl -s -m 1 http://169.254.169.254/latest/meta-data/ 2>/dev/null" 2>/dev/null | grep -q .; then
        echo "AWS"
    else
        echo "Unknown"
    fi
    
    echo ""
}

# Test working server
if timeout 10 ping -c 1 $WORKING_IP > /dev/null 2>&1; then
    collect_server_info "$WORKING_IP" "WORKING"
else
    echo -e "${YELLOW}⚠️  Cannot reach working server ($WORKING_IP)${NC}\n"
fi

# Test failing servers
for ip in "${FAILING_IPS[@]}"; do
    if timeout 10 ping -c 1 $ip > /dev/null 2>&1; then
        collect_server_info "$ip" "FAILING"
    else
        echo -e "${YELLOW}⚠️  Cannot reach server ($ip)${NC}\n"
    fi
done

# Summary and recommendations
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}RECOMMENDATIONS:${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}\n"

echo -e "${GREEN}If servers are on GCP:${NC}"
echo -e "1. Open GCP Console (console.cloud.google.com)"
echo -e "2. Navigate to VPC Network > Firewall rules"
echo -e "3. Create a new ingress rule with:"
echo -e "   - Name: allow-openalgo-8888"
echo -e "   - Direction: Ingress"
echo -e "   - Action: Allow"
echo -e "   - Priority: 1000"
echo -e "   - Protocols and ports:"
echo -e "     ☑ Specified protocols and ports"
echo -e "     ☑ tcp:8888"
echo -e "   - Source IP ranges: 0.0.0.0/0"
echo -e "   - Target tags: (optional, set on VMs)"
echo ""
echo -e "${GREEN}Or via gcloud CLI (run from your local machine):${NC}"
echo -e "  ${YELLOW}gcloud compute firewall-rules create allow-openalgo-8888 \\${NC}"
echo -e "  ${YELLOW}    --allow=tcp:8888 \\${NC}"
echo -e "  ${YELLOW}    --source-ranges=0.0.0.0/0${NC}"
echo ""

echo -e "${GREEN}If servers are on AWS:${NC}"
echo -e "1. Go to EC2 Dashboard"
echo -e "2. Select each instance"
echo -e "3. Go to Security groups"
echo -e "4. Edit inbound rules"
echo -e "5. Add rule:"
echo -e "   - Type: Custom TCP Rule"
echo -e "   - Port Range: 8888"
echo -e "   - Source: 0.0.0.0/0"
echo ""

echo -e "${YELLOW}Testing from local machine:${NC}"
echo -e "  ${GREEN}curl -v http://34.14.188.9:8888/health${NC}"
echo -e "  ${GREEN}curl -v http://34.14.189.59:8888/health${NC}"
