#!/bin/bash

# ============================================================
# OpenAlgo Quick Setup - Single Instance with 4GB Swap
# ============================================================

set -e

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

# Function to check command status
check_status() {
    if [ $? -ne 0 ]; then
        log_message "Error: $1" "$RED"
        exit 1
    fi
}

# Banner
echo -e "${BLUE}"
echo "  ██████╗ ██████╗ ███████╗███╗   ██╗ █████╗ ██╗      ██████╗  ██████╗ "
echo " ██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔══██╗██║     ██╔════╝ ██╔═══██╗"
echo " ██║   ██║██████╔╝███████╗██╔██╗ ██║███████║██║     ██║  ███╗██║   ██║"
echo " ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██╔══██║██║     ██║   ██║██║   ██║"
echo " ╚██████╔╝██╗     ███████╗██║ ╚████║██║  ██║███████╗╚██████╔╝╚██████╔╝"
echo "  ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝╚═╝  ╚══════╝ ╚═════╝  ╚═════╝ "
echo "            QUICK SETUP - SINGLE INSTANCE (4GB SWAP)                   "
echo -e "${NC}"

log_message "\n📋 This script will perform the following setup steps:" "$BLUE"
echo "   1. Update system packages"
echo "   2. Configure 4GB swap memory"
echo "   3. Install OpenAlgo single instance"
echo "   4. Set up SSL certificate"
echo "   5. Create systemd service"
echo ""

read -p "Continue with setup? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_message "❌ Setup cancelled by user" "$RED"
    exit 0
fi

# Step 1: Update system
log_message "\n╔════════════════════════════════════╗" "$BLUE"
log_message "║ Step 1: Update System Packages     ║" "$BLUE"
log_message "╚════════════════════════════════════╝" "$BLUE"

log_message "\n🔄 Updating package lists..." "$BLUE"
sudo apt update
check_status "Failed to update package lists"

log_message "🔄 Upgrading packages..." "$BLUE"
sudo apt upgrade -y
check_status "Failed to upgrade packages"

log_message "✅ System packages updated successfully" "$GREEN"

# Step 2: Configure 4GB Swap
log_message "\n╔════════════════════════════════════╗" "$BLUE"
log_message "║ Step 2: Configure 4GB Swap         ║" "$BLUE"
log_message "╚════════════════════════════════════╝" "$BLUE"

SWAPFILE="/swapfile"

log_message "\n🔍 Checking existing swap..." "$BLUE"

# Check if swap already exists
if [ -f "$SWAPFILE" ] && swapon --show | grep -q "$SWAPFILE"; then
    log_message "✓ 4GB swap already configured" "$GREEN"
else
    log_message "🛠️  Creating 4GB swap..." "$BLUE"
    
    # Disable any existing swap
    if grep -q "$SWAPFILE" /etc/fstab; then
        log_message "   Removing old swap configuration..." "$BLUE"
        sudo sed -i "\|$SWAPFILE|d" /etc/fstab
    fi
    
    # Remove old swapfile if it exists
    if [ -f "$SWAPFILE" ]; then
        log_message "   Removing old swap file..." "$BLUE"
        sudo rm -f "$SWAPFILE" 2>/dev/null || {
            log_message "⚠️  Could not remove old swap (reboot may be needed)" "$YELLOW"
            log_message "   Attempting to continue..." "$YELLOW"
        }
    fi
    
    # Create new 4GB swap
    log_message "   Allocating 4GB swap space..." "$BLUE"
    sudo fallocate -l 4G "$SWAPFILE"
    check_status "Failed to allocate swap space"
    
    log_message "   Setting permissions..." "$BLUE"
    sudo chmod 600 "$SWAPFILE"
    
    log_message "   Formatting swap..." "$BLUE"
    sudo mkswap "$SWAPFILE"
    check_status "Failed to format swap"
    
    log_message "   Enabling swap..." "$BLUE"
    sudo swapon "$SWAPFILE"
    check_status "Failed to enable swap"
    
    log_message "   Making swap persistent..." "$BLUE"
    echo "$SWAPFILE none swap sw 0 0" | sudo tee -a /etc/fstab > /dev/null

    log_message "   Setting swappiness to 15..." "$BLUE"
    sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null <<'EOF'
vm.swappiness=15
EOF
    sudo sysctl -p /etc/sysctl.d/99-swappiness.conf
    
    log_message "✅ 4GB swap configured successfully" "$GREEN"
fi

# Step 3: Collect Instance Configuration
log_message "\n╔════════════════════════════════════╗" "$BLUE"
log_message "║ Step 3: Collect Instance Details  ║" "$BLUE"
log_message "╚════════════════════════════════════╝" "$BLUE"

# Get domain
log_message "\n📝 Enter instance configuration details:" "$BLUE"

while true; do
    read -p "   Domain/Subdomain (e.g., trade.example.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        log_message "   ❌ Domain is required" "$RED"
        continue
    fi
    if [[ ! $DOMAIN =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?))+$ ]]; then
        log_message "   ❌ Invalid domain format" "$RED"
        continue
    fi
    break
done

log_message "\n   ℹ️  Valid brokers: fivepaisa, aliceblue, angel, compositedge, definedge, dhan," "$BLUE"
log_message "      dhan_sandbox, firstock, flattrade, fyers, groww, ibulls, iifl," "$BLUE"
log_message "      indmoney, jainamxts, kotak, motilal, mstock, paytm, pocketful," "$BLUE"
log_message "      samco, shoonya, tradejini, upstox, wisdom, zebu, zerodha" "$BLUE"

while true; do
    read -p "   Broker name: " BROKER
    if [ -z "$BROKER" ]; then
        log_message "   ❌ Broker name is required" "$RED"
        continue
    fi
    break
done

log_message "\n   Redirect URL: https://${DOMAIN}/${BROKER}/callback" "$GREEN"

read -p "   Broker API Key: " API_KEY
if [ -z "$API_KEY" ]; then
    log_message "❌ API Key is required" "$RED"
    exit 1
fi

read -p "   Broker API Secret: " API_SECRET
if [ -z "$API_SECRET" ]; then
    log_message "❌ API Secret is required" "$RED"
    exit 1
fi

# Check for XTS brokers
XTS_BROKERS="fivepaisaxts,compositedge,ibulls,iifl,jainamxts,wisdom"
if [[ ",$XTS_BROKERS," == *",$BROKER,"* ]]; then
    log_message "\n   ℹ️  This broker requires market data credentials" "$YELLOW"
    read -p "   Market Data API Key: " API_KEY_MARKET
    read -p "   Market Data API Secret: " API_SECRET_MARKET
    IS_XTS="true"
else
    API_KEY_MARKET=""
    API_SECRET_MARKET=""
    IS_XTS="false"
fi

# Step 4: Install OpenAlgo
log_message "\n╔════════════════════════════════════╗" "$BLUE"
log_message "║ Step 4: Install OpenAlgo           ║" "$BLUE"
log_message "╚════════════════════════════════════╝" "$BLUE"

BASE_DIR="/var/python/openalgo-flask"
INSTANCE_DIR="$BASE_DIR/openalgo1"
SERVICE_DOMAIN="${DOMAIN//./-}"
SERVICE_NAME="openalgo-$SERVICE_DOMAIN"
REPO_URL="https://github.com/marketcalls/openalgo.git"

log_message "\n📥 Setting up OpenAlgo instance..." "$BLUE"

# Install system dependencies
log_message "   Installing system packages..." "$BLUE"
sudo apt-get install -y python3 python3-venv python3-pip python3-full nginx git software-properties-common snapd ufw certbot python3-certbot-nginx > /dev/null 2>&1
check_status "Failed to install system packages"

# Install uv
if ! command -v uv &> /dev/null; then
    log_message "   Installing uv package manager..." "$BLUE"
    sudo snap install astral-uv --classic > /dev/null 2>&1
    check_status "Failed to install uv"
fi

# Create base directory
sudo mkdir -p "$BASE_DIR"

# Clone repository
if [ ! -d "$INSTANCE_DIR" ]; then
    log_message "   Cloning OpenAlgo repository..." "$BLUE"
    sudo git clone "$REPO_URL" "$INSTANCE_DIR" > /dev/null 2>&1
    check_status "Failed to clone repository"
fi

# Create domain-named symlink for easier identification
DOMAIN_SYMLINK="$BASE_DIR/openalgo-$SERVICE_DOMAIN"
sudo ln -sfn "$INSTANCE_DIR" "$DOMAIN_SYMLINK"

# Create virtual environment
log_message "   Setting up Python virtual environment..." "$BLUE"
if [ -d "$INSTANCE_DIR/venv" ]; then
    sudo rm -rf "$INSTANCE_DIR/venv"
fi
sudo uv venv "$INSTANCE_DIR/venv" > /dev/null 2>&1
check_status "Failed to create virtual environment"

# Install dependencies
log_message "   Installing Python dependencies..." "$BLUE"
ACTIVATE_CMD="source $INSTANCE_DIR/venv/bin/activate"
sudo bash -c "$ACTIVATE_CMD && uv pip install -r $INSTANCE_DIR/requirements-nginx.txt" > /dev/null 2>&1
check_status "Failed to install Python dependencies"

# Install gunicorn and eventlet
sudo bash -c "$ACTIVATE_CMD && uv pip install gunicorn eventlet" > /dev/null 2>&1

log_message "✅ OpenAlgo installed successfully" "$GREEN"

# Step 5: Configure Instance
log_message "\n╔════════════════════════════════════╗" "$BLUE"
log_message "║ Step 5: Configure Instance         ║" "$BLUE"
log_message "╚════════════════════════════════════╝" "$BLUE"

log_message "\n🔧 Configuring .env file..." "$BLUE"

ENV_FILE="$INSTANCE_DIR/.env"

if [ -f "$ENV_FILE" ]; then
    sudo mv "$ENV_FILE" "${ENV_FILE}.backup_$(date +%Y%m%d_%H%M%S)"
fi

sudo cp "$INSTANCE_DIR/.sample.env" "$ENV_FILE"

if sudo grep -q "^DOMAIN=" "$ENV_FILE"; then
    sudo sed -i "s|^DOMAIN=.*|DOMAIN=$DOMAIN|g" "$ENV_FILE"
else
    echo "DOMAIN=$DOMAIN" | sudo tee -a "$ENV_FILE" > /dev/null
fi

# Generate keys
APP_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
API_KEY_PEPPER=$(python3 -c "import secrets; print(secrets.token_hex(32))")

# Update .env file
sudo sed -i "s|<broker>|$BROKER|g" "$ENV_FILE"
sudo sed -i "s|http://127.0.0.1:5000|https://$DOMAIN|g" "$ENV_FILE"
sudo sed -i "s|CORS_ALLOWED_ORIGINS = '.*'|CORS_ALLOWED_ORIGINS = 'https://$DOMAIN'|g" "$ENV_FILE"
sudo sed -i "s|FLASK_PORT='[0-9]*'|FLASK_PORT='5000'|g" "$ENV_FILE"
sudo sed -i "s|WEBSOCKET_PORT='[0-9]*'|WEBSOCKET_PORT='8765'|g" "$ENV_FILE"
sudo sed -i "s|ZMQ_PORT='[0-9]*'|ZMQ_PORT='5555'|g" "$ENV_FILE"
sudo sed -i "s|WEBSOCKET_URL='.*'|WEBSOCKET_URL='wss://$DOMAIN/ws'|g" "$ENV_FILE"
sudo sed -i "s|WEBSOCKET_HOST='127.0.0.1'|WEBSOCKET_HOST='0.0.0.0'|g" "$ENV_FILE"
sudo sed -i "s|ZMQ_HOST='127.0.0.1'|ZMQ_HOST='0.0.0.0'|g" "$ENV_FILE"
sudo sed -i "s|YOUR_BROKER_API_KEY|$API_KEY|g" "$ENV_FILE"
sudo sed -i "s|YOUR_BROKER_API_SECRET|$API_SECRET|g" "$ENV_FILE"
sudo sed -i "s|3daa0403ce2501ee7432b75bf100048e3cf510d63d2754f952e93d88bf07ea84|$APP_KEY|g" "$ENV_FILE"
sudo sed -i "s|a25d94718479b170c16278e321ea6c989358bf499a658fd20c90033cef8ce772|$API_KEY_PEPPER|g" "$ENV_FILE"

if [ "$IS_XTS" = "true" ]; then
    sudo sed -i "s|YOUR_BROKER_MARKET_API_KEY|$API_KEY_MARKET|g" "$ENV_FILE"
    sudo sed -i "s|YOUR_BROKER_MARKET_API_SECRET|$API_SECRET_MARKET|g" "$ENV_FILE"
fi

log_message "✅ .env configured successfully" "$GREEN"

# Set permissions
log_message "🔐 Setting file permissions..." "$BLUE"
sudo mkdir -p "$INSTANCE_DIR/db"
sudo mkdir -p "$INSTANCE_DIR/tmp"
sudo mkdir -p "$INSTANCE_DIR/strategies/scripts"
sudo mkdir -p "$INSTANCE_DIR/strategies/examples"
sudo mkdir -p "$INSTANCE_DIR/log/strategies"
sudo mkdir -p "$INSTANCE_DIR/keys"
sudo chown -R www-data:www-data "$INSTANCE_DIR"
sudo chmod -R 755 "$INSTANCE_DIR"
sudo chmod 700 "$INSTANCE_DIR/keys"

# Step 6: Configure Nginx
log_message "\n╔════════════════════════════════════╗" "$BLUE"
log_message "║ Step 6: Configure Nginx & SSL      ║" "$BLUE"
log_message "╚════════════════════════════════════╝" "$BLUE"

log_message "\n🔒 Configuring Nginx for SSL..." "$BLUE"

# Initial HTTP config
sudo tee /etc/nginx/sites-available/$DOMAIN > /dev/null << EOL
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    root /var/www/html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOL

sudo ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# Test and reload nginx
sudo nginx -t > /dev/null 2>&1
check_status "Failed to validate Nginx config"
sudo systemctl reload nginx

# Get SSL certificate
log_message "   Obtaining SSL certificate..." "$BLUE"
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email admin@${DOMAIN#*.} > /dev/null 2>&1
check_status "Failed to obtain SSL certificate"

log_message "✅ SSL certificate obtained successfully" "$GREEN"

# Final Nginx config with SSL
log_message "   Configuring final Nginx setup..." "$BLUE"

SOCKET_FILE="$INSTANCE_DIR/openalgo.sock"

sudo tee /etc/nginx/sites-available/$DOMAIN > /dev/null << EOL
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location = /ws {
        return 301 https://\$host\$request_uri;
    }

    location /ws/ {
        return 301 https://\$host\$request_uri;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers EECDH+AESGCM:EDH+AESGCM;
    ssl_ecdh_curve secp384r1;
    ssl_session_timeout 10m;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;

    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Strict-Transport-Security "max-age=63072000" always;

    location = /ws {
        proxy_pass http://127.0.0.1:8765;
        proxy_http_version 1.1;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /ws/ {
        proxy_pass http://127.0.0.1:8765/;
        proxy_http_version 1.1;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://unix:$SOCKET_FILE;
        proxy_http_version 1.1;
        proxy_read_timeout 300s;
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
    }
}
EOL

sudo nginx -t > /dev/null 2>&1
check_status "Failed to validate final Nginx config"

# Step 7: Create Systemd Service
log_message "\n╔════════════════════════════════════╗" "$BLUE"
log_message "║ Step 7: Create Systemd Service     ║" "$BLUE"
log_message "╚════════════════════════════════════╝" "$BLUE"

log_message "\n🔧 Creating systemd service..." "$BLUE"

VENV_PATH="$INSTANCE_DIR/venv"

sudo tee /etc/systemd/system/$SERVICE_NAME.service > /dev/null << EOL
[Unit]
Description=OpenAlgo Instance 1 ($DOMAIN - $BROKER)
After=network.target

[Service]
User=www-data
Group=www-data
WorkingDirectory=$INSTANCE_DIR
ExecStart=/bin/bash -c 'source $VENV_PATH/bin/activate && $VENV_PATH/bin/gunicorn \\
    --worker-class eventlet \\
    -w 1 \\
    --bind unix:$SOCKET_FILE \\
    --log-level info \\
    app:app'
Restart=always
RestartSec=5
TimeoutSec=60

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl start "$SERVICE_NAME"
check_status "Failed to start OpenAlgo service"

# Wait for service to be ready
sleep 3

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    log_message "⚠️  Service started but may not be ready yet" "$YELLOW"
    log_message "   Waiting for broker connection..." "$YELLOW"
    sleep 10
fi

log_message "✅ Systemd service created and started" "$GREEN"

# Step 8: Firewall Configuration
log_message "\n╔════════════════════════════════════╗" "$BLUE"
log_message "║ Step 8: Configure Firewall         ║" "$BLUE"
log_message "╚════════════════════════════════════╝" "$BLUE"

log_message "\n🔒 Configuring UFW firewall..." "$BLUE"

sudo ufw default deny incoming > /dev/null 2>&1
sudo ufw default allow outgoing > /dev/null 2>&1
sudo ufw allow ssh > /dev/null 2>&1
sudo ufw allow 'Nginx Full' > /dev/null 2>&1
sudo ufw --force enable > /dev/null 2>&1

log_message "✅ Firewall configured successfully" "$GREEN"

# Final Nginx reload
log_message "\n🔄 Reloading Nginx..." "$BLUE"
sudo systemctl reload nginx

# Summary
log_message "\n╔════════════════════════════════════════════════════════╗" "$GREEN"
log_message "║          SETUP COMPLETED SUCCESSFULLY!                 ║" "$GREEN"
log_message "╚════════════════════════════════════════════════════════╝" "$GREEN"

log_message "\n📋 INSTANCE INFORMATION:" "$YELLOW"
log_message "   Instance: openalgo1" "$BLUE"
log_message "   Domain: https://$DOMAIN" "$BLUE"
log_message "   Broker: $BROKER" "$BLUE"
log_message "   Directory: $INSTANCE_DIR" "$BLUE"
log_message "   Service: $SERVICE_NAME" "$BLUE"

log_message "\n🔌 NETWORK CONFIGURATION:" "$YELLOW"
log_message "   Flask Port: 5000 (internal)" "$BLUE"
log_message "   WebSocket Port: 8765 (internal)" "$BLUE"
log_message "   ZMQ Port: 5555 (internal)" "$BLUE"

log_message "\n📊 SYSTEM CONFIGURATION:" "$YELLOW"
log_message "   Swap: 4GB (active)" "$BLUE"
log_message "   Firewall: UFW enabled" "$BLUE"
log_message "   SSL: Let's Encrypt (auto-renewal enabled)" "$BLUE"

log_message "\n📚 USEFUL COMMANDS:" "$YELLOW"
log_message "   View logs: sudo journalctl -u $SERVICE_NAME -f" "$BLUE"
log_message "   Check status: sudo systemctl status $SERVICE_NAME" "$BLUE"
log_message "   Restart instance: sudo systemctl restart $SERVICE_NAME" "$BLUE"
log_message "   Stop instance: sudo systemctl stop $SERVICE_NAME" "$BLUE"
log_message "   Start instance: sudo systemctl start $SERVICE_NAME" "$BLUE"

log_message "\n🎉 OpenAlgo is ready to use!" "$GREEN"
log_message "   Access at: https://$DOMAIN" "$GREEN"

log_message "\n💡 Next steps:" "$YELLOW"
log_message "   1. Wait 1-2 minutes for the broker to authenticate" "$YELLOW"
log_message "   2. Open https://$DOMAIN in your browser" "$YELLOW"
log_message "   3. Check the logs if you encounter any issues" "$YELLOW"
