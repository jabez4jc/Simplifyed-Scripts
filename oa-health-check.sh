#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
BASE_DIR="/var/python/openalgo-flask"
HEALTH_OK=0
HEALTH_WARNING=0
HEALTH_CRITICAL=0

# Helper functions
print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}\n"
}

print_ok() {
    echo -e "${GREEN}✓${NC} $1"
    ((HEALTH_OK++))
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
    ((HEALTH_WARNING++))
}

print_critical() {
    echo -e "${RED}✗${NC} $1"
    ((HEALTH_CRITICAL++))
}

# Extract domain from instance directory name (for newer naming convention)
get_domain_from_dir() {
    local dir_name="$1"
    # For openalgo1, openalgo2 style: extract from .env or systemd service
    # Return instance number for now
    if [[ $dir_name =~ ^openalgo([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$dir_name"
    fi
}

# Check if instance directory exists
check_instance_directory() {
    local instance_name="$1"
    local instance_dir="$BASE_DIR/$instance_name"
    
    if [ -d "$instance_dir" ]; then
        print_ok "Directory exists: $instance_dir"
        return 0
    else
        print_critical "Directory missing: $instance_dir"
        return 1
    fi
}

# Check systemd service status
check_service_status() {
    local instance_name="$1"
    local service_name="openalgo$instance_name"
    
    if systemctl is-active --quiet "$service_name"; then
        print_ok "Service running: $service_name"
        return 0
    else
        local status=$(systemctl is-active "$service_name")
        print_critical "Service not running ($status): $service_name"
        return 1
    fi
}

# Check if Flask port is listening
check_flask_port() {
    local instance_num="$1"
    local flask_port=$((5000 + instance_num))
    
    if ss -tlnp 2>/dev/null | grep -q ":$flask_port "; then
        print_ok "Flask port listening: localhost:$flask_port"
        return 0
    else
        print_warning "Flask port not listening: localhost:$flask_port"
        return 1
    fi
}

# Check if WebSocket port is listening
check_websocket_port() {
    local instance_num="$1"
    local ws_port=$((8765 + instance_num))
    
    if ss -tlnp 2>/dev/null | grep -q ":$ws_port "; then
        print_ok "WebSocket port listening: localhost:$ws_port"
        return 0
    else
        print_warning "WebSocket port not listening: localhost:$ws_port"
        return 1
    fi
}

# Check if ZMQ port is listening
check_zmq_port() {
    local instance_num="$1"
    local zmq_port=$((5555 + instance_num))
    
    if ss -tlnp 2>/dev/null | grep -q ":$zmq_port "; then
        print_ok "ZMQ port listening: localhost:$zmq_port"
        return 0
    else
        print_warning "ZMQ port not listening: localhost:$zmq_port"
        return 1
    fi
}

# Check .env file exists and contains required fields
check_env_file() {
    local instance_dir="$1"
    local env_file="$instance_dir/.env"
    
    if [ ! -f "$env_file" ]; then
        print_critical ".env file missing: $env_file"
        return 1
    fi
    
    print_ok ".env file exists"
    
    # Check for critical variables
    local required_vars=("DATABASE_URL" "FLASK_PORT" "BROKER")
    for var in "${required_vars[@]}"; do
        if grep -q "^$var=" "$env_file"; then
            print_ok ".env contains $var"
        else
            print_warning ".env missing $var"
        fi
    done
}

# Check databases exist
check_databases() {
    local instance_dir="$1"
    local instance_num="$2"
    
    local db_dir="$instance_dir/db"
    if [ ! -d "$db_dir" ]; then
        print_warning "Database directory missing: $db_dir"
        return 1
    fi
    
    local db_files=("openalgo${instance_num}.db" "latency${instance_num}.db" "logs${instance_num}.db")
    for db_file in "${db_files[@]}"; do
        if [ -f "$db_dir/$db_file" ]; then
            local size=$(du -h "$db_dir/$db_file" | cut -f1)
            print_ok "Database exists: $db_file ($size)"
        else
            print_warning "Database missing: $db_file"
        fi
    done
}

# Check disk space for instance
check_disk_space() {
    local instance_dir="$1"
    
    local usage=$(du -sh "$instance_dir" 2>/dev/null | cut -f1)
    print_ok "Disk usage: $usage"
    
    # Get overall filesystem usage
    local filesystem=$(df "$instance_dir" | tail -1 | awk '{print $1}')
    local percent=$(df "$instance_dir" | tail -1 | awk '{print $5}' | sed 's/%//')
    
    if [ "$percent" -gt 90 ]; then
        print_critical "Filesystem nearly full: $percent% used on $filesystem"
    elif [ "$percent" -gt 80 ]; then
        print_warning "Filesystem getting full: $percent% used on $filesystem"
    else
        print_ok "Filesystem usage: $percent%"
    fi
}

# Check virtual environment
check_venv() {
    local instance_dir="$1"
    local venv_path="$instance_dir/venv"
    
    if [ ! -d "$venv_path" ]; then
        print_critical "Virtual environment missing: $venv_path"
        return 1
    fi
    
    if [ -f "$venv_path/bin/activate" ]; then
        print_ok "Virtual environment exists"
        return 0
    else
        print_critical "Virtual environment corrupted: $venv_path/bin/activate missing"
        return 1
    fi
}

# Check socket file
check_socket() {
    local instance_dir="$1"
    local socket_file="$instance_dir/openalgo.sock"
    
    if [ -S "$socket_file" ]; then
        print_ok "Socket file exists: openalgo.sock"
        return 0
    else
        print_warning "Socket file missing or not a socket: openalgo.sock"
        return 1
    fi
}

# Check recent errors in logs
check_recent_errors() {
    local instance_name="$1"
    local service_name="openalgo$instance_name"
    
    # Get last 20 lines of journalctl
    local error_count=$(sudo journalctl -u "$service_name" -n 100 2>/dev/null | grep -i "error\|exception\|traceback" | wc -l)
    
    if [ "$error_count" -eq 0 ]; then
        print_ok "No recent errors in logs"
    elif [ "$error_count" -lt 5 ]; then
        print_warning "Found $error_count errors in recent logs"
    else
        print_critical "Found $error_count errors in recent logs"
    fi
}

# Test HTTP endpoint
check_http_endpoint() {
    local instance_dir="$1"
    local domain=""
    
    # Try to extract domain from .env
    if [ -f "$instance_dir/.env" ]; then
        domain=$(grep "DOMAIN=" "$instance_dir/.env" | cut -d'=' -f2 | tr -d "'" | head -1)
    fi
    
    # If domain not found, try nginx config lookup
    if [ -z "$domain" ]; then
        domain=$(ls -1 /etc/nginx/sites-available/ 2>/dev/null | head -1)
    fi
    
    if [ -n "$domain" ]; then
        if timeout 5 curl -s -k "https://$domain" > /dev/null 2>&1; then
            print_ok "HTTPS endpoint responding: https://$domain"
            return 0
        else
            print_warning "HTTPS endpoint not responding: https://$domain"
            return 1
        fi
    else
        print_warning "Could not determine domain for HTTP test"
        return 1
    fi
}

# Check file permissions
check_permissions() {
    local instance_dir="$1"
    
    # Check if owned by www-data
    local owner=$(stat -c %U "$instance_dir" 2>/dev/null || stat -f %Su "$instance_dir" 2>/dev/null)
    
    if [ "$owner" = "www-data" ] || [ "$owner" = "root" ]; then
        print_ok "Directory ownership correct: $owner"
    else
        print_warning "Directory ownership unexpected: $owner (expected www-data or root)"
    fi
    
    # Check keys directory is restricted
    local keys_dir="$instance_dir/keys"
    if [ -d "$keys_dir" ]; then
        local perms=$(stat -c %a "$keys_dir" 2>/dev/null || stat -f %a "$keys_dir" 2>/dev/null)
        if [ "$perms" = "700" ] || [ "$perms" = "750" ]; then
            print_ok "Keys directory permissions secure: $perms"
        else
            print_warning "Keys directory permissions may be too open: $perms"
        fi
    fi
}

# Main health check for a single instance
check_instance() {
    local instance_name="$1"
    local instance_dir="$BASE_DIR/$instance_name"
    
    # Extract instance number for port calculations
    local instance_num=$(echo "$instance_name" | sed 's/[^0-9]*//g')
    
    print_header "Instance: $instance_name"
    
    # If no number found, use instance_name as is
    if [ -z "$instance_num" ]; then
        instance_num=1
    fi
    
    check_instance_directory "$instance_name" || return 1
    check_service_status "$instance_num"
    check_flask_port "$instance_num"
    check_websocket_port "$instance_num"
    check_zmq_port "$instance_num"
    check_env_file "$instance_dir"
    check_databases "$instance_dir" "$instance_num"
    check_disk_space "$instance_dir"
    check_venv "$instance_dir"
    check_socket "$instance_dir"
    check_recent_errors "$instance_num"
    check_permissions "$instance_dir"
}

# System-wide checks
check_system_health() {
    print_header "System Health"
    
    # Check Nginx
    if systemctl is-active --quiet nginx; then
        print_ok "Nginx service running"
    else
        print_critical "Nginx service not running"
    fi
    
    # Check systemd
    if sudo systemctl daemon-reload > /dev/null 2>&1; then
        print_ok "Systemd responsive"
    else
        print_critical "Systemd issues detected"
    fi
    
    # Check firewall
    if sudo ufw status | grep -q "active"; then
        print_ok "Firewall enabled"
    else
        print_warning "Firewall disabled"
    fi
    
    # Check swap
    local swap=$(free -h | grep Swap | awk '{print $2}')
    if [ "$swap" != "0B" ]; then
        local swap_used=$(free -h | grep Swap | awk '{print $3}')
        print_ok "Swap configured: $swap (using $swap_used)"
    else
        print_warning "No swap configured"
    fi
    
    # Check system load
    local load=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
    print_ok "System load: $load"
}

# Print summary
print_summary() {
    echo -e "\n${BLUE}=== SUMMARY ===${NC}\n"
    echo -e "${GREEN}✓ Passed: $HEALTH_OK${NC}"
    if [ $HEALTH_WARNING -gt 0 ]; then
        echo -e "${YELLOW}⚠ Warnings: $HEALTH_WARNING${NC}"
    fi
    if [ $HEALTH_CRITICAL -gt 0 ]; then
        echo -e "${RED}✗ Critical: $HEALTH_CRITICAL${NC}"
    fi
    
    echo ""
    if [ $HEALTH_CRITICAL -eq 0 ]; then
        if [ $HEALTH_WARNING -eq 0 ]; then
            echo -e "${GREEN}Overall status: HEALTHY${NC}"
            return 0
        else
            echo -e "${YELLOW}Overall status: WARNING${NC}"
            return 1
        fi
    else
        echo -e "${RED}Overall status: CRITICAL${NC}"
        return 2
    fi
}

# Show menu for instance selection
show_menu() {
    echo ""
    log_message "=== HEALTH CHECK OPTIONS ===" "$BLUE"
    
    local instances=($(ls -1 "$BASE_DIR" 2>/dev/null | grep "^openalgo"))
    
    if [ ${#instances[@]} -eq 0 ]; then
        log_message "❌ No OpenAlgo instances found in $BASE_DIR" "$RED"
        return 1
    fi
    
    echo "Available instances:"
    local i=1
    for inst in "${instances[@]}"; do
        echo "$i) $inst"
        ((i++))
    done
    echo "$i) 🔍 Check ALL instances"
    echo "$((i+1))) System health only"
    echo ""
    
    local total_options=$((i+1))
    read -p "Select option [1-$total_options]: " choice
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > total_options )); then
        log_message "Invalid choice" "$RED"
        return 1
    fi
    
    if [ $choice -eq $i ]; then
        check_all_instances
    elif [ $choice -eq $((i+1)) ]; then
        check_system_health
        print_summary
    else
        local selected="${instances[$((choice - 1))]}"
        check_system_health
        check_instance "$selected"
        print_summary
    fi
}

# Check all instances
check_all_instances() {
    local instances=($(ls -1 "$BASE_DIR" 2>/dev/null | grep "^openalgo"))
    
    check_system_health
    
    for instance in "${instances[@]}"; do
        check_instance "$instance"
    done
    
    print_summary
}

# Main execution
main() {
    echo -e "${BLUE}"
    echo "  ██████╗ ██████╗ ███████╗███╗   ██╗ █████╗ ██╗      ██████╗  ██████╗ "
    echo " ██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔══██╗██║     ██╔════╝ ██╔═══██╗"
    echo " ██║   ██║██████╔╝███████╗██╔██╗ ██║███████║██║     ██║  ███╗██║   ██║"
    echo " ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██╔══██║██║     ██║   ██║██║   ██║"
    echo " ╚██████╔╝██╗     ███████╗██║ ╚████║██║  ██║███████╗╚██████╔╝╚██████╔╝"
    echo "  ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝╚═╝  ╚══════╝ ╚═════╝  ╚═════╝ "
    echo "                      HEALTH CHECK UTILITY                             "
    echo -e "${NC}"
    
    # Check if base directory exists
    if [ ! -d "$BASE_DIR" ]; then
        echo -e "${RED}✗ Base directory not found: $BASE_DIR${NC}"
        exit 1
    fi
    
    # Get list of instances
    local instances=($(ls -1 "$BASE_DIR" 2>/dev/null | grep "^openalgo"))
    
    if [ ${#instances[@]} -eq 0 ]; then
        echo -e "${YELLOW}ℹ No OpenAlgo instances found in $BASE_DIR${NC}"
        exit 0
    fi
    
    # Handle command-line arguments
    if [ $# -eq 0 ]; then
        show_menu
    else
        local command="$1"
        if [ "$command" = "all" ]; then
            check_all_instances
        elif [ "$command" = "system" ]; then
            check_system_health
            print_summary
        elif [ -d "$BASE_DIR/$command" ]; then
            check_system_health
            check_instance "$command"
            print_summary
        else
            log_message "Usage: $0 [all|system|INSTANCE_NAME]" "$YELLOW"
            exit 1
        fi
    fi
    
    exit $?
}

main "$@"
