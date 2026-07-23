#!/bin/bash
# oa-secure-admin.sh
# Retrofit login protection in front of the OpenAlgo admin pages
# (per-instance /monitor and the all-instances manager on :8888) on a
# server that was already set up before this protection existed.
#
# Auth is handled by openalgo-restart-api.py itself (a styled login page +
# session cookie), not nginx's auth_basic - that way the login prompt is
# our own UI instead of the browser's native Basic Auth dialog. If an
# earlier version of this script (or multi-install.sh) already added
# auth_basic to your nginx vhosts, this run removes it, since leaving both
# in place would mean two logins stacked on top of each other.
#
# What it does, in order (each step can be skipped):
#   1. Set/reset the admin login (delegates to openalgo-restart-api.py
#      --set-admin-password, which owns the credential store).
#   2. Remove any leftover nginx auth_basic directives from a previous
#      run of this script, since the app now handles auth end-to-end.
#   3. Optionally put the manager page (currently only reachable at
#      http://<server-ip>:8888/) behind its own domain + TLS instead of
#      raw IP:port.
#   4. Optionally close public access to port 8888 and bind the API to
#      127.0.0.1 once nginx is confirmed as the only way in.
#
# Safe to re-run: an already-configured manager domain is detected and
# left alone unless you choose to reconfigure it.

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_message() {
    local message="$1"
    local color="${2:-$NC}"
    echo -e "${color}${message}${NC}"
}

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_message "ERROR: Run as root (use sudo)." "$RED"
        exit 1
    fi
}

API_SCRIPT="/usr/local/bin/openalgo-restart-api.py"
LEGACY_HTPASSWD="/etc/nginx/openalgo-admin.htpasswd"
SITES_AVAILABLE="/etc/nginx/sites-available"
SERVICE_NAME="openalgo-restart-api"
OVERRIDE_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
OVERRIDE_FILE="$OVERRIDE_DIR/override.conf"

current_manager_domain() {
    [ -f "$OVERRIDE_FILE" ] || return 0
    grep -oP '(?<=^Environment=MANAGER_DOMAIN=).*' "$OVERRIDE_FILE" 2>/dev/null || true
}

current_bind() {
    [ -f "$OVERRIDE_FILE" ] || { echo "0.0.0.0"; return 0; }
    grep -oP '(?<=^Environment=OPENALGO_BIND=).*' "$OVERRIDE_FILE" 2>/dev/null || echo "0.0.0.0"
}

write_override() {
    # Merges MANAGER_DOMAIN/OPENALGO_BIND into the systemd drop-in, preserving
    # whichever of the two isn't being changed in this call.
    local domain="$1" bind="$2"
    mkdir -p "$OVERRIDE_DIR"
    {
        echo "[Service]"
        [ -n "$domain" ] && echo "Environment=MANAGER_DOMAIN=$domain"
        [ -n "$bind" ] && echo "Environment=OPENALGO_BIND=$bind"
    } > "$OVERRIDE_FILE"
    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME"
}

step_credentials() {
    log_message "\n=== STEP 1: Admin login ===" "$YELLOW"
    if [ ! -f "$API_SCRIPT" ]; then
        log_message "$API_SCRIPT not found - install/update it via api-manager.sh first." "$RED"
        return 1
    fi
    python3 "$API_SCRIPT" --set-admin-password
}

step_clean_vhost_auth() {
    log_message "\n=== STEP 2: Remove nginx-level auth (superseded by app login) ===" "$YELLOW"
    if [ ! -d "$SITES_AVAILABLE" ]; then
        log_message "No $SITES_AVAILABLE directory found, skipping." "$YELLOW"
        return 0
    fi

    local cleaned=0
    local file
    for file in "$SITES_AVAILABLE"/*; do
        [ -f "$file" ] || continue
        if ! grep -q 'auth_basic_user_file .*openalgo-admin.htpasswd' "$file"; then
            continue
        fi
        sed -i \
            -e '/auth_basic "OpenAlgo Admin";/d' \
            -e '/auth_basic_user_file .*openalgo-admin\.htpasswd;/d' \
            "$file"
        log_message "  cleaned: $file" "$GREEN"
        cleaned=$((cleaned+1))
    done
    log_message "Done. Cleaned: $cleaned vhost(s)." "$GREEN"

    if [ "$cleaned" -gt 0 ]; then
        if nginx -t && systemctl reload nginx; then
            log_message "✅ nginx reloaded." "$GREEN"
        else
            log_message "nginx config test failed after cleanup — check the files above before reloading manually." "$RED"
        fi
    fi

    if [ -f "$LEGACY_HTPASSWD" ]; then
        log_message "Note: $LEGACY_HTPASSWD is no longer used by anything and can be deleted whenever you like." "$BLUE"
    fi
}

step_manager_domain() {
    log_message "\n=== STEP 3: Dedicated domain for the manager page (optional) ===" "$YELLOW"
    local existing
    existing=$(current_manager_domain)
    if [ -n "$existing" ]; then
        log_message "Manager domain already configured: https://$existing/" "$GREEN"
        read -p "Reconfigure it? (y/N): " reconf
        [[ "$reconf" =~ ^[Yy]$ ]] || return 0
    fi

    read -p "Domain for the manager page (DNS must already point at this server's IP, blank to skip): " domain
    if [ -z "$domain" ]; then
        log_message "Skipped." "$BLUE"
        return 0
    fi

    log_message "Configuring nginx for $domain (HTTP, for the certbot challenge)..." "$BLUE"
    tee "$SITES_AVAILABLE/$domain" > /dev/null << EOL
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    root /var/www/html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOL
    ln -sf "$SITES_AVAILABLE/$domain" "/etc/nginx/sites-enabled/$domain"
    nginx -t && systemctl reload nginx
    if [ $? -ne 0 ]; then
        log_message "nginx config test failed, aborting domain setup." "$RED"
        return 1
    fi

    log_message "Obtaining SSL certificate for $domain..." "$BLUE"
    certbot --nginx -d "$domain" --non-interactive --agree-tos --email "admin@${domain#*.}"
    if [ $? -ne 0 ]; then
        log_message "certbot failed, aborting domain setup." "$RED"
        return 1
    fi

    log_message "Configuring final HTTPS vhost for $domain..." "$BLUE"
    tee "$SITES_AVAILABLE/$domain" > /dev/null << EOL
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $domain;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header Strict-Transport-Security "max-age=63072000" always;

    # Auth is handled by openalgo-restart-api.py's own login page/session,
    # not nginx - this is a plain reverse proxy.
    location / {
        proxy_pass http://127.0.0.1:8888;
        proxy_http_version 1.1;
        proxy_read_timeout 60s;
        proxy_connect_timeout 10s;
        proxy_send_timeout 60s;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL
    nginx -t && systemctl reload nginx
    if [ $? -ne 0 ]; then
        log_message "nginx config test failed on final vhost, aborting." "$RED"
        return 1
    fi

    write_override "$domain" "$(current_bind)"
    log_message "✅ Manager page now at https://$domain/" "$GREEN"
}

step_close_port() {
    log_message "\n=== STEP 4: Close public port 8888 (optional) ===" "$YELLOW"
    local domain
    domain=$(current_manager_domain)
    if [ -z "$domain" ]; then
        log_message "No manager domain configured yet (step 3) — skipping, you'd lose access entirely." "$BLUE"
        return 0
    fi

    log_message "The manager page is reachable at https://$domain/ now." "$GREEN"
    read -p "Close public access to port 8888 and bind the API to localhost only? (y/N): " close_choice
    [[ "$close_choice" =~ ^[Yy]$ ]] || { log_message "Left port 8888 open." "$BLUE"; return 0; }

    if command -v ufw &>/dev/null; then
        ufw delete allow 8888/tcp > /dev/null 2>&1 || true
        ufw delete allow 8888/udp > /dev/null 2>&1 || true
        log_message "✅ Removed public ufw allow rules for 8888." "$GREEN"
    fi

    write_override "$domain" "127.0.0.1"
    log_message "✅ API now bound to 127.0.0.1 (nginx still reaches it locally)." "$GREEN"
}

main() {
    need_root
    log_message "OpenAlgo Admin Security Setup" "$BLUE"
    step_credentials
    step_clean_vhost_auth
    step_manager_domain
    step_close_port

    log_message "\n=== Summary ===" "$YELLOW"
    local domain
    domain=$(current_manager_domain)
    if [ -n "$domain" ]; then
        log_message "Manager:  https://$domain/ (login required)" "$GREEN"
    else
        SERVER_IP=$(curl -s -m 3 https://api.ipify.org 2>/dev/null)
        [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || SERVER_IP=$(hostname -I | awk '{print $1}')
        log_message "Manager:  http://$SERVER_IP:8888/ (set up a domain via this script to make this memorable)" "$YELLOW"
    fi
    log_message "Monitor:  https://<instance-domain>/monitor (login required)" "$GREEN"
}

main "$@"
