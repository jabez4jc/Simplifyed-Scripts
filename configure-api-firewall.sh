#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}=== OpenAlgo API Firewall Configuration ===${NC}\n"

PORT=8888

# Check current firewall status
echo -e "${YELLOW}Checking firewall configuration...${NC}\n"

# UFW Check
if command -v ufw &>/dev/null; then
    echo -e "${BLUE}Detected: UFW (Ubuntu Firewall)${NC}"
    
    ufw_status=$(sudo ufw status 2>/dev/null | head -1)
    echo "Status: $ufw_status"
    
    if echo "$ufw_status" | grep -q "active"; then
        echo -e "\n${YELLOW}UFW is ACTIVE${NC}"
        
        # Check if 8888 is already allowed
        if sudo ufw status | grep -q "8888"; then
            echo -e "${GREEN}✅ Port 8888 is already allowed in UFW${NC}"
        else
            echo -e "${RED}❌ Port 8888 is NOT allowed in UFW${NC}"
            echo -e "\n${YELLOW}Adding port 8888 to UFW...${NC}"
            sudo ufw allow 8888/tcp
            sudo ufw allow 8888/udp
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ Port 8888 added to UFW${NC}"
            else
                echo -e "${RED}❌ Failed to add port to UFW${NC}"
            fi
        fi
    else
        echo -e "${GREEN}ℹ️  UFW is INACTIVE${NC}"
    fi
else
    echo -e "${BLUE}UFW not found${NC}"
fi

# iptables Check
echo -e "\n${YELLOW}Checking iptables rules...${NC}"
if command -v iptables &>/dev/null; then
    echo "Current iptables INPUT rules:"
    sudo iptables -L INPUT -n -v 2>/dev/null | grep -E "ACCEPT|DENY" | head -10 || echo "Unable to list iptables rules"
    
    # Check if 8888 is explicitly blocked
    if sudo iptables -L INPUT -n | grep -q "REJECT.*8888\|DROP.*8888"; then
        echo -e "${RED}❌ Port 8888 appears to be BLOCKED in iptables${NC}"
        echo -e "\n${YELLOW}Removing blocking rule...${NC}"
        sudo iptables -D INPUT -p tcp --dport 8888 -j REJECT 2>/dev/null || true
        sudo iptables -D INPUT -p tcp --dport 8888 -j DROP 2>/dev/null || true
    fi
    
    # Check if 8888 is explicitly allowed
    if sudo iptables -L INPUT -n | grep -q "ACCEPT.*8888"; then
        echo -e "${GREEN}✅ Port 8888 is ACCEPTED in iptables${NC}"
    else
        echo -e "${YELLOW}⚠️  Port 8888 may not be explicitly allowed${NC}"
        echo "Adding rule to allow port 8888..."
        sudo iptables -A INPUT -p tcp --dport 8888 -j ACCEPT 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ Rule added${NC}"
        fi
    fi
else
    echo "iptables not found"
fi

# firewalld Check (RHEL/CentOS)
if command -v firewall-cmd &>/dev/null; then
    echo -e "\n${BLUE}Detected: firewalld${NC}"
    
    status=$(sudo firewall-cmd --state 2>/dev/null)
    echo "Status: $status"
    
    if echo "$status" | grep -q "running"; then
        echo -e "\n${YELLOW}firewalld is RUNNING${NC}"
        
        if sudo firewall-cmd --list-ports 2>/dev/null | grep -q "8888"; then
            echo -e "${GREEN}✅ Port 8888 is already open${NC}"
        else
            echo -e "${RED}❌ Port 8888 is NOT open in firewalld${NC}"
            echo -e "\n${YELLOW}Opening port 8888...${NC}"
            sudo firewall-cmd --add-port=8888/tcp --permanent
            sudo firewall-cmd --reload
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ Port 8888 opened in firewalld${NC}"
            fi
        fi
    fi
else
    echo -e "\nfirewalld not found"
fi

# Cloud Firewall Check (GCP, AWS, Azure)
echo -e "\n${YELLOW}Cloud Platform Firewall Check...${NC}"

# Check GCP metadata
if curl -s -m 2 -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/" &>/dev/null; then
    echo -e "${BLUE}Detected: Google Cloud Platform (GCP)${NC}"
    echo -e "${YELLOW}⚠️  GCP firewall rules must be configured via GCP Console${NC}"
    echo "Steps:"
    echo "1. Go to VPC > Firewall rules"
    echo "2. Create a new ingress rule"
    echo "3. Allow TCP port 8888"
    echo "4. Source IP range: 0.0.0.0/0 (or specific IPs)"
    
    # Try to get current instance info
    INSTANCE_ID=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/id" 2>/dev/null)
    if [ ! -z "$INSTANCE_ID" ]; then
        echo -e "\nInstance ID: $INSTANCE_ID"
        echo "Firewall rule example (run from your local machine):"
        echo "  gcloud compute firewall-rules create allow-8888 \\"
        echo "    --allow=tcp:8888 \\"
        echo "    --source-ranges=0.0.0.0/0"
    fi
fi

# Check AWS metadata
if curl -s -m 2 http://169.254.169.254/latest/meta-data/ &>/dev/null; then
    echo -e "${BLUE}Detected: Amazon Web Services (AWS)${NC}"
    echo -e "${YELLOW}⚠️  AWS Security Group rules must be configured via AWS Console${NC}"
    echo "Steps:"
    echo "1. Go to EC2 > Security Groups"
    echo "2. Select the security group for this instance"
    echo "3. Add inbound rule: Protocol=TCP, Port=8888, Source=0.0.0.0/0"
    
    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
    if [ ! -z "$INSTANCE_ID" ]; then
        echo -e "\nInstance ID: $INSTANCE_ID"
    fi
fi

# Check Azure metadata
if curl -s -m 2 -H "Metadata:true" "http://169.254.169.254/metadata/instance?api-version=2021-02-01" &>/dev/null; then
    echo -e "${BLUE}Detected: Microsoft Azure${NC}"
    echo -e "${YELLOW}⚠️  Azure Network Security Group rules must be configured via Azure Portal${NC}"
    echo "Steps:"
    echo "1. Go to the resource group containing this VM"
    echo "2. Select the Network Security Group"
    echo "3. Add inbound security rule:"
    echo "   - Protocol: TCP"
    echo "   - Destination Port: 8888"
    echo "   - Source: Any (0.0.0.0/0) or specific IPs"
fi

# Test connectivity
echo -e "\n${YELLOW}Testing port connectivity...${NC}"

# Get server IP
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "Server IP: $SERVER_IP"

# Test from localhost
timeout 2 curl -s http://localhost:8888/health > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ localhost:8888 accessible${NC}"
else
    echo -e "${RED}❌ localhost:8888 NOT accessible${NC}"
fi

# Test from server IP
timeout 2 curl -s http://$SERVER_IP:8888/health > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ $SERVER_IP:8888 accessible${NC}"
else
    echo -e "${RED}❌ $SERVER_IP:8888 NOT accessible${NC}"
fi

# Summary
echo -e "\n${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}FIREWALL CONFIGURATION SUMMARY${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"

echo -e "\n${YELLOW}If you're using a Cloud Platform (GCP, AWS, Azure):${NC}"
echo -e "Port 8888 must be allowed in the CLOUD FIREWALL settings, not just the OS firewall."
echo -e "\n${YELLOW}For GCP specifically:${NC}"
echo -e "Run this command from your local machine:"
echo -e "  ${GREEN}gcloud compute firewall-rules create allow-openalgo-8888 \\${NC}"
echo -e "  ${GREEN}  --allow=tcp:8888 \\${NC}"
echo -e "  ${GREEN}  --source-ranges=0.0.0.0/0${NC}"
echo -e "\n${YELLOW}To target specific instances:${NC}"
echo -e "  ${GREEN}gcloud compute firewall-rules create allow-openalgo-8888 \\${NC}"
echo -e "  ${GREEN}  --allow=tcp:8888 \\${NC}"
echo -e "  ${GREEN}  --target-tags=openalgo${NC}"
echo -e "\nThen tag your GCP instances with 'openalgo' label"
