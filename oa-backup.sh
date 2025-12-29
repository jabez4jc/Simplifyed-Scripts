#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
BASE_DIR="/var/python/openalgo-flask"
BACKUP_DIR="${1:-.}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_LOG="$BACKUP_DIR/backup_${TIMESTAMP}.log"

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Function to log messages
log_message() {
    local message="$1"
    local color="$2"
    echo -e "${color}${message}${NC}" | tee -a "$BACKUP_LOG"
}

# Function to check command status
check_status() {
    if [ $? -ne 0 ]; then
        log_message "Error: $1" "$RED"
        return 1
    fi
    return 0
}

# Function to calculate directory size
get_size() {
    du -sh "$1" 2>/dev/null | cut -f1
}

# Backup instance .env file
backup_env_file() {
    local instance_dir="$1"
    local instance_name=$(basename "$instance_dir")
    local env_file="$instance_dir/.env"
    
    if [ ! -f "$env_file" ]; then
        log_message "⚠ .env not found for $instance_name, skipping" "$YELLOW"
        return 1
    fi
    
    local backup_file="$BACKUP_DIR/${instance_name}_env_${TIMESTAMP}.enc"
    
    # Encrypt .env file (for security of API credentials)
    if command -v gpg &> /dev/null; then
        sudo gpg --symmetric --cipher-algo AES256 --output "$backup_file" "$env_file" 2>/dev/null
        if [ $? -eq 0 ]; then
            sudo chown $(whoami) "$backup_file"
            log_message "✓ Backed up .env (encrypted): $instance_name" "$GREEN"
            return 0
        else
            log_message "⚠ GPG encryption failed, backing up plain text" "$YELLOW"
        fi
    fi
    
    # Fallback: plain text backup (less secure)
    backup_file="$BACKUP_DIR/${instance_name}_env_${TIMESTAMP}.env"
    sudo cp "$env_file" "$backup_file"
    check_status "Failed to backup .env for $instance_name" || return 1
    sudo chown $(whoami) "$backup_file"
    chmod 600 "$backup_file"
    log_message "✓ Backed up .env (plain text): $instance_name" "$GREEN"
    return 0
}

# Backup instance databases
backup_databases() {
    local instance_dir="$1"
    local instance_name=$(basename "$instance_dir")
    local db_dir="$instance_dir/db"
    
    if [ ! -d "$db_dir" ]; then
        log_message "⚠ Database directory not found for $instance_name, skipping" "$YELLOW"
        return 1
    fi
    
    local backup_file="$BACKUP_DIR/${instance_name}_databases_${TIMESTAMP}.tar.gz"
    
    # Backup all database files
    sudo tar -czf "$backup_file" -C "$db_dir" . 2>/dev/null
    check_status "Failed to backup databases for $instance_name" || return 1
    
    sudo chown $(whoami) "$backup_file"
    local size=$(get_size "$backup_file")
    log_message "✓ Backed up databases: $instance_name ($size)" "$GREEN"
    return 0
}

# Backup complete instance (optional)
backup_full_instance() {
    local instance_dir="$1"
    local instance_name=$(basename "$instance_dir")
    local backup_file="$BACKUP_DIR/${instance_name}_full_${TIMESTAMP}.tar.gz"
    
    log_message "  Archiving complete instance (this may take a while)..." "$BLUE"
    
    # Exclude venv and tmp directories to save space
    sudo tar -czf "$backup_file" \
        --exclude='venv' \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        --exclude='.git' \
        -C "$BASE_DIR" "$instance_name" 2>/dev/null
    
    check_status "Failed to backup complete instance $instance_name" || return 1
    
    sudo chown $(whoami) "$backup_file"
    local size=$(get_size "$backup_file")
    log_message "✓ Full instance backup: $instance_name ($size)" "$GREEN"
    return 0
}

# Backup nginx configuration
backup_nginx_config() {
    local instance_name="$1"
    local domain=""
    
    # Find domain from nginx config
    domain=$(ls -1 /etc/nginx/sites-available/ 2>/dev/null | grep -i "$instance_name" | head -1)
    
    if [ -z "$domain" ]; then
        return 0
    fi
    
    local nginx_conf="/etc/nginx/sites-available/$domain"
    if [ ! -f "$nginx_conf" ]; then
        return 0
    fi
    
    local backup_file="$BACKUP_DIR/${instance_name}_nginx_${TIMESTAMP}.conf"
    sudo cp "$nginx_conf" "$backup_file"
    sudo chown $(whoami) "$backup_file"
    log_message "✓ Backed up nginx config: $domain" "$GREEN"
    return 0
}

# Backup systemd service file
backup_service_file() {
    local instance_name="$1"
    local instance_num=$(echo "$instance_name" | sed 's/[^0-9]*//g')
    local service_name="openalgo$instance_num"
    local service_file="/etc/systemd/system/$service_name.service"
    
    if [ ! -f "$service_file" ]; then
        return 0
    fi
    
    local backup_file="$BACKUP_DIR/${instance_name}_systemd_${TIMESTAMP}.service"
    sudo cp "$service_file" "$backup_file"
    sudo chown $(whoami) "$backup_file"
    log_message "✓ Backed up systemd service: $service_name" "$GREEN"
    return 0
}

# Restore .env file
restore_env_file() {
    local backup_file="$1"
    local instance_name="$2"
    local instance_dir="$BASE_DIR/$instance_name"
    local env_file="$instance_dir/.env"
    
    if [ ! -f "$backup_file" ]; then
        log_message "❌ Backup file not found: $backup_file" "$RED"
        return 1
    fi
    
    # Check if encrypted
    if [[ "$backup_file" == *.enc ]]; then
        if ! command -v gpg &> /dev/null; then
            log_message "❌ GPG not available to decrypt file" "$RED"
            return 1
        fi
        # GPG will prompt for password
        sudo gpg --decrypt "$backup_file" | sudo tee "$env_file" > /dev/null
    else
        sudo cp "$backup_file" "$env_file"
    fi
    
    check_status "Failed to restore .env" || return 1
    sudo chown www-data:www-data "$env_file"
    sudo chmod 644 "$env_file"
    
    log_message "✓ Restored .env: $instance_name" "$GREEN"
    return 0
}

# Restore databases
restore_databases() {
    local backup_file="$1"
    local instance_name="$2"
    local instance_dir="$BASE_DIR/$instance_name"
    local db_dir="$instance_dir/db"
    
    if [ ! -f "$backup_file" ]; then
        log_message "❌ Backup file not found: $backup_file" "$RED"
        return 1
    fi
    
    # Create backup of current databases
    if [ -d "$db_dir" ]; then
        local current_backup="$db_dir/backup_before_restore_$(date +%Y%m%d_%H%M%S)"
        sudo mkdir -p "$current_backup"
        sudo cp "$db_dir"/*.db "$current_backup/" 2>/dev/null || true
        log_message "  Current databases backed up to: $current_backup" "$BLUE"
    fi
    
    # Restore databases
    sudo mkdir -p "$db_dir"
    sudo tar -xzf "$backup_file" -C "$db_dir"
    check_status "Failed to restore databases" || return 1
    
    sudo chown -R www-data:www-data "$db_dir"
    log_message "✓ Restored databases: $instance_name" "$GREEN"
    return 0
}

# List available backups
list_backups() {
    echo ""
    log_message "Available backups in $BACKUP_DIR:" "$BLUE"
    echo ""
    
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -1 "$BACKUP_DIR" 2>/dev/null)" ]; then
        log_message "No backups found" "$YELLOW"
        return
    fi
    
    ls -lh "$BACKUP_DIR"/*_${TIMESTAMP%_*}_* 2>/dev/null | \
        awk '{print $9, "(" $5 ")"}' | \
        sed "s|$BACKUP_DIR/||g"
    
    echo ""
}

# Clean old backups
cleanup_old_backups() {
    local retention_days="${1:-30}"
    local count=0
    
    log_message "\nCleaning backups older than $retention_days days..." "$BLUE"
    
    find "$BACKUP_DIR" -maxdepth 1 -name "*_*_*.tar.gz" -o -name "*_*_*.enc" -o -name "*_*_*.env" | \
    while read -r file; do
        local file_age=$(($(date +%s) - $(stat -f%m "$file" 2>/dev/null || stat -c%Y "$file")))
        local file_days=$((file_age / 86400))
        
        if [ $file_days -gt $retention_days ]; then
            sudo rm -f "$file"
            log_message "✓ Deleted: $(basename "$file")" "$GREEN"
            ((count++))
        fi
    done
    
    if [ $count -eq 0 ]; then
        log_message "✓ No old backups to clean" "$GREEN"
    else
        log_message "✓ Cleaned $count old backup(s)" "$GREEN"
    fi
}

# Interactive menu
show_menu() {
    echo ""
    log_message "=== BACKUP OPERATIONS ===" "$BLUE"
    
    local instances=($(ls -1 "$BASE_DIR" 2>/dev/null | grep "^openalgo"))
    
    if [ ${#instances[@]} -eq 0 ]; then
        log_message "❌ No OpenAlgo instances found in $BASE_DIR" "$RED"
        return 1
    fi
    
    echo "1) Backup specific instance (env + databases)"
    echo "2) Backup specific instance (full archive)"
    echo "3) Backup all instances (env + databases)"
    echo "4) Backup all instances (full archive)"
    echo "5) Restore from backup"
    echo "6) List available backups"
    echo "7) Clean old backups"
    echo "8) Exit"
    echo ""
    read -p "Select option [1-8]: " choice
    
    case $choice in
        1) backup_mode="single"; backup_type="quick" ;;
        2) backup_mode="single"; backup_type="full" ;;
        3) backup_mode="all"; backup_type="quick" ;;
        4) backup_mode="all"; backup_type="full" ;;
        5) backup_mode="restore" ;;
        6) list_backups; exit 0 ;;
        7) cleanup_old_backups 30; exit 0 ;;
        8) exit 0 ;;
        *) log_message "Invalid option" "$RED"; exit 1 ;;
    esac
}

# Select single instance for backup
select_instance_for_backup() {
    local instances=($(ls -1 "$BASE_DIR" 2>/dev/null | grep "^openalgo"))
    
    if [ ${#instances[@]} -eq 0 ]; then
        log_message "❌ No OpenAlgo instances found" "$RED"
        return 1
    fi
    
    echo ""
    echo "Available instances:"
    local i=1
    for inst in "${instances[@]}"; do
        echo "$i) $inst"
        ((i++))
    done
    echo ""
    
    read -p "Select instance [1-$((i-1))]: " inst_choice
    
    if ! [[ "$inst_choice" =~ ^[0-9]+$ ]] || (( inst_choice < 1 || inst_choice >= i )); then
        log_message "Invalid choice" "$RED"
        return 1
    fi
    
    echo "${instances[$((inst_choice - 1))]}"
}

# Main backup operation
backup_instances() {
    local backup_mode="$1"
    local backup_type="$2"
    
    # Get list of instances
    local instances=($(ls -1 "$BASE_DIR" 2>/dev/null | grep "^openalgo"))
    
    if [ ${#instances[@]} -eq 0 ]; then
        log_message "❌ No OpenAlgo instances found in $BASE_DIR" "$RED"
        return 1
    fi
    
    # If single mode, prompt for instance selection
    if [ "$backup_mode" = "single" ]; then
        local selected=$(select_instance_for_backup)
        if [ -z "$selected" ]; then
            return 1
        fi
        instances=("$selected")
    fi
    
    log_message "Backing up ${#instances[@]} instance(s) to: $BACKUP_DIR" "$BLUE"
    log_message "Log file: $BACKUP_LOG" "$BLUE"
    log_message "" "$BLUE"
    
    local backed_up=0
    
    for instance in "${instances[@]}"; do
        local instance_dir="$BASE_DIR/$instance"
        
        log_message "Processing instance: $instance" "$BLUE"
        
        if [ "$backup_type" = "quick" ]; then
            backup_env_file "$instance_dir" && ((backed_up++))
            backup_databases "$instance_dir" && ((backed_up++))
            backup_nginx_config "$instance" && ((backed_up++))
            backup_service_file "$instance" && ((backed_up++))
        elif [ "$backup_type" = "full" ]; then
            backup_env_file "$instance_dir" && ((backed_up++))
            backup_full_instance "$instance_dir" && ((backed_up++))
            backup_nginx_config "$instance" && ((backed_up++))
            backup_service_file "$instance" && ((backed_up++))
        fi
        
        echo ""
    done
    
    log_message "Backup complete! $backed_up item(s) backed up." "$GREEN"
    list_backups
}

# Restore operation
restore_operation() {
    echo ""
    log_message "=== RESTORE BACKUP ===" "$BLUE"
    
    # Get list of instances
    local instances=($(ls -1 "$BASE_DIR" 2>/dev/null | grep "^openalgo"))
    
    if [ ${#instances[@]} -eq 0 ]; then
        log_message "❌ No OpenAlgo instances found" "$RED"
        return 1
    fi
    
    # Select instance
    echo "Available instances:"
    local i=1
    for inst in "${instances[@]}"; do
        echo "$i) $inst"
        ((i++))
    done
    echo ""
    
    read -p "Select instance to restore [1-$i]: " inst_choice
    
    if ! [[ "$inst_choice" =~ ^[0-9]+$ ]] || (( inst_choice < 1 || inst_choice > i-1 )); then
        log_message "Invalid choice" "$RED"
        return 1
    fi
    
    local selected_instance="${instances[$((inst_choice - 1))]}"
    
    # Select backup type
    echo ""
    echo "Restore options:"
    echo "1) Restore .env file only"
    echo "2) Restore databases only"
    echo "3) Both .env and databases"
    echo ""
    
    read -p "Select restore type [1-3]: " restore_choice
    
    echo ""
    echo "Available backups for $selected_instance:"
    ls -1 "$BACKUP_DIR"/${selected_instance}_*_*.tar.gz "$BACKUP_DIR"/${selected_instance}_*_*.enc "$BACKUP_DIR"/${selected_instance}_*_*.env 2>/dev/null | \
        awk '{print NR ") " $1}' | sed "s|$BACKUP_DIR/||g"
    
    echo ""
    read -p "Select backup file number: " backup_choice
    
    local backup_files=($(ls -1 "$BACKUP_DIR"/${selected_instance}_*_*.tar.gz "$BACKUP_DIR"/${selected_instance}_*_*.enc "$BACKUP_DIR"/${selected_instance}_*_*.env 2>/dev/null))
    
    if ! [[ "$backup_choice" =~ ^[0-9]+$ ]] || (( backup_choice < 1 || backup_choice > ${#backup_files[@]} )); then
        log_message "Invalid backup file selection" "$RED"
        return 1
    fi
    
    local selected_backup="${backup_files[$((backup_choice - 1))]}"
    
    log_message "⚠ WARNING: This will overwrite current data!" "$YELLOW"
    read -p "Are you sure? (type 'yes' to confirm): " confirm
    
    if [ "$confirm" != "yes" ]; then
        log_message "Restore cancelled" "$YELLOW"
        return 1
    fi
    
    case $restore_choice in
        1)
            if [[ "$selected_backup" == *.enc ]] || [[ "$selected_backup" == *.env ]]; then
                restore_env_file "$selected_backup" "$selected_instance"
            else
                log_message "❌ Selected backup is not an .env file" "$RED"
            fi
            ;;
        2)
            if [[ "$selected_backup" == *.tar.gz ]]; then
                restore_databases "$selected_backup" "$selected_instance"
            else
                log_message "❌ Selected backup is not a database archive" "$RED"
            fi
            ;;
        3)
            # Try to find matching env and database backups
            local base_filename=$(echo "$(basename "$selected_backup")" | cut -d'_' -f1-2)
            local env_backup=$(ls -1 "$BACKUP_DIR"/${base_filename}_env_*.enc "$BACKUP_DIR"/${base_filename}_env_*.env 2>/dev/null | tail -1)
            local db_backup=$(ls -1 "$BACKUP_DIR"/${base_filename}_databases_*.tar.gz 2>/dev/null | tail -1)
            
            if [ -n "$env_backup" ]; then
                restore_env_file "$env_backup" "$selected_instance"
            fi
            
            if [ -n "$db_backup" ]; then
                restore_databases "$db_backup" "$selected_instance"
            fi
            ;;
    esac
    
    log_message "" "$BLUE"
    log_message "⚠ Remember to restart the instance after restore:" "$YELLOW"
    log_message "  sudo systemctl restart openalgo<N>" "$YELLOW"
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
    echo "                      BACKUP & RESTORE UTILITY                         "
    echo -e "${NC}"
    
    # Check if base directory exists
    if [ ! -d "$BASE_DIR" ]; then
        log_message "❌ Base directory not found: $BASE_DIR" "$RED"
        exit 1
    fi
    
    # Show menu if no arguments
    if [ $# -eq 0 ]; then
        show_menu
        backup_mode="${backup_mode:-all}"
        backup_type="${backup_type:-quick}"
    else
        backup_mode="$1"
        backup_type="${2:-quick}"
    fi
    
    case $backup_mode in
        single) backup_instances "single" "$backup_type" ;;
        all) backup_instances "all" "$backup_type" ;;
        restore) restore_operation ;;
        list) list_backups ;;
        cleanup) cleanup_old_backups "${2:-30}" ;;
        *)
            log_message "Usage: $0 [single|all|restore|list|cleanup] [quick|full]" "$YELLOW"
            exit 1
            ;;
    esac
}

main "$@"
