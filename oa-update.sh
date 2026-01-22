#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
BASE_DIR="/var/python/openalgo-flask"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
UPDATE_LOG="/tmp/update_${TIMESTAMP}.log"

# Function to log messages
log_message() {
    local message="$1"
    local color="$2"
    echo -e "${color}${message}${NC}" | tee -a "$UPDATE_LOG"
}

get_service_name() {
    local instance_dir="$1"
    local fallback_id="$2"
    local env_file="$instance_dir/.env"
    local domain=""

    if [ -f "$env_file" ]; then
        domain=$(grep -E "^DOMAIN=" "$env_file" | head -1 | cut -d'=' -f2- | tr -d "'" | tr -d '"')
    fi

    if [ -n "$domain" ]; then
        echo "openalgo-${domain//./-}"
    elif [[ "$fallback_id" == openalgo* ]]; then
        echo "$fallback_id"
    else
        echo "openalgo$fallback_id"
    fi
}

# Function to check command status
check_status() {
    if [ $? -ne 0 ]; then
        log_message "Error: $1" "$RED"
        return 1
    fi
    return 0
}

ensure_uv() {
    if command -v uv >/dev/null 2>&1; then
        return 0
    fi

    log_message "uv not found, installing..." "$YELLOW"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -y > /dev/null 2>&1
        sudo apt-get install -y uv > /dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y uv > /dev/null 2>&1
    else
        log_message "❌ Unable to install uv (unsupported package manager)" "$RED"
        return 1
    fi

    if command -v uv >/dev/null 2>&1; then
        log_message "✓ uv installed" "$GREEN"
        return 0
    fi

    log_message "❌ uv installation failed" "$RED"
    return 1
}

# Function to get git status
get_git_status() {
    local instance_dir="$1"
    
    if [ ! -d "$instance_dir/.git" ]; then
        return 1
    fi
    
    cd "$instance_dir"
    local branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    local remote=$(git config --get remote.origin.url 2>/dev/null)
    local commit=$(git rev-parse --short HEAD 2>/dev/null)
    
    echo "$branch|$remote|$commit"
}

# Function to backup before update
backup_before_update() {
    local instance_name="$1"
    local instance_dir="$BASE_DIR/$instance_name"
    
    log_message "  Creating pre-update backup..." "$BLUE"
    
    # Create a quick backup of .env, .sample.env, and db
    local backup_dir="/tmp/openalgo_backup_${instance_name}_${TIMESTAMP}"
    mkdir -p "$backup_dir"
    
    if [ -f "$instance_dir/.env" ]; then
        sudo cp "$instance_dir/.env" "$backup_dir/"
    fi
    
    if [ -f "$instance_dir/.sample.env" ]; then
        sudo cp "$instance_dir/.sample.env" "$backup_dir/"
    fi
    
    if [ -d "$instance_dir/db" ]; then
        sudo cp -r "$instance_dir/db" "$backup_dir/"
    fi
    
    # Set readable permissions
    sudo chown -R $(whoami) "$backup_dir"
    
    echo "$backup_dir"
}

# Merge .env file with new version
merge_env_file() {
    local instance_dir="$1"
    local backup_dir="$2"
    local env_file="$instance_dir/.env"
    local sample_env="$instance_dir/.sample.env"
    local old_env="$backup_dir/.env"
    
    # If no sample template exists, keep current .env
    if [ ! -f "$sample_env" ]; then
        log_message "⚠ .sample.env not found, keeping current .env" "$YELLOW"
        return 0
    fi
    
    # If no old .env exists, nothing to merge
    if [ ! -f "$old_env" ]; then
        log_message "⚠ Previous .env backup not found, keeping current .env" "$YELLOW"
        return 0
    fi
    
    # Get ENV_CONFIG_VERSION from both files
    local new_version=$(sudo grep "ENV_CONFIG_VERSION" "$sample_env" | grep -oE "'[^']*'" | tr -d "'")
    local old_version=$(sudo grep "ENV_CONFIG_VERSION" "$old_env" | grep -oE "'[^']*'" | tr -d "'")
    
    # If versions are not found, fall back to MD5 comparison
    if [ -z "$new_version" ] || [ -z "$old_version" ]; then
        log_message "⚠ ENV_CONFIG_VERSION not found, using hash comparison" "$YELLOW"
        
        local sample_env_hash=$(sudo md5sum "$sample_env" | awk '{print $1}')
        local old_sample_hash=""
        
        if [ -f "$backup_dir/.sample.env" ]; then
            old_sample_hash=$(sudo md5sum "$backup_dir/.sample.env" | awk '{print $1}')
        fi
        
        if [ -n "$old_sample_hash" ] && [ "$sample_env_hash" = "$old_sample_hash" ]; then
            log_message "    ✓ .sample.env unchanged, keeping current .env" "$GREEN"
            return 0
        fi
    else
        # Compare versions
        if [ "$new_version" = "$old_version" ]; then
            log_message "    ✓ ENV_CONFIG_VERSION unchanged ($new_version), keeping current .env" "$GREEN"
            return 0
        fi
        
        log_message "    Detected ENV_CONFIG_VERSION change ($old_version → $new_version), merging..." "$BLUE"
    fi
    
    # Create temporary merged file
    local temp_env=$(mktemp)
    sudo cp "$sample_env" "$temp_env"
    
    # Extract key variables from old .env and preserve them in new template
    local keys_to_preserve=("BROKER" "FLASK_PORT" "WEBSOCKET_PORT" "ZMQ_PORT" "DATABASE_URL" "LATENCY_DATABASE_URL" "LOGS_DATABASE_URL" "SESSION_COOKIE_NAME" "CSRF_COOKIE_NAME" "FLASK_HOST_IP" "WEBSOCKET_HOST" "WEBSOCKET_URL" "CORS_ALLOWED_ORIGINS" "YOUR_BROKER_API_KEY" "YOUR_BROKER_API_SECRET" "YOUR_BROKER_MARKET_API_KEY" "YOUR_BROKER_MARKET_API_SECRET" "APP_KEY" "API_KEY_PEPPER")
    
    for key in "${keys_to_preserve[@]}"; do
        # Get the value from old .env
        local old_value=$(sudo grep "^${key}=" "$old_env" | cut -d'=' -f2-)
        
        if [ -n "$old_value" ]; then
            # Replace placeholder in new template with old value
            sudo sed -i "s|^${key}=.*|${key}=${old_value}|g" "$temp_env"
        fi
    done
    
    # Also check for any custom variables in old .env that might not be in template
    sudo grep "^[A-Z_]*=" "$old_env" | while IFS='=' read -r key value; do
        if ! sudo grep -q "^${key}=" "$temp_env"; then
            # Add custom variable to new .env if it doesn't exist
            echo "${key}=${value}" | sudo tee -a "$temp_env" > /dev/null
        fi
    done
    
    # Replace current .env with merged version
    sudo cp "$temp_env" "$env_file"
    sudo chown www-data:www-data "$env_file"
    sudo chmod 644 "$env_file"
    rm -f "$temp_env"
    
    log_message "    ✓ .env merged (preserved: ports, broker, credentials, keys)" "$GREEN"
    return 0
}

# Function to update single instance
update_instance() {
    local instance_name="$1"
    local instance_dir="$BASE_DIR/$instance_name"
    local instance_num=$(echo "$instance_name" | sed 's/[^0-9]*//g')
    local service_name
    service_name=$(get_service_name "$instance_dir" "$instance_num")
    
    log_message "\n--- Updating Instance: $instance_name ---" "$BLUE"
    
    # Check if instance directory exists
    if [ ! -d "$instance_dir" ]; then
        log_message "❌ Instance directory not found: $instance_dir" "$RED"
        return 1
    fi
    
    # Get current git status
    local git_status=$(get_git_status "$instance_dir")
    if [ $? -eq 0 ]; then
        IFS='|' read -r branch remote commit <<< "$git_status"
        log_message "Current branch: $branch" "$BLUE"
        log_message "Current commit: $commit" "$BLUE"
    else
        log_message "❌ Not a git repository: $instance_dir" "$RED"
        return 1
    fi
    
    # Create backup
    local backup_dir=$(backup_before_update "$instance_name")
    check_status "Failed to create backup" || return 1

    # Ensure uv is available
    ensure_uv || return 1
    
    # Check service status before update
    local was_running=false
    if systemctl is-active --quiet "$service_name"; then
        was_running=true
        log_message "  Stopping service: $service_name" "$BLUE"
        sudo systemctl stop "$service_name"
        check_status "Failed to stop service" || return 1
        
        # Wait for service to stop
        sleep 2
    fi
    
    # Fetch latest changes
    log_message "  Fetching latest changes..." "$BLUE"
    cd "$instance_dir"
    sudo git fetch origin 2>&1 | tee -a "$UPDATE_LOG"
    check_status "Failed to fetch updates" || {
        [ "$was_running" = true ] && sudo systemctl start "$service_name"
        return 1
    }
    
    # Show available updates
    log_message "\n  Available updates:" "$BLUE"
    sudo git log --oneline HEAD..origin/main -10 2>/dev/null | while read -r line; do
        log_message "    $line" "$BLUE"
    done
    
    # Merge/rebase latest changes
    log_message "  Pulling latest changes..." "$BLUE"
    sudo git pull origin main --ff-only 2>&1 | tee -a "$UPDATE_LOG"
    
    if [ $? -ne 0 ]; then
        log_message "⚠ Fast-forward merge failed. Repository may have local changes." "$YELLOW"
        log_message "  Manual intervention needed. Backup saved at: $backup_dir" "$YELLOW"
        [ "$was_running" = true ] && sudo systemctl start "$service_name"
        return 1
    fi
    
    # Get new commit
    local new_commit=$(git rev-parse --short HEAD 2>/dev/null)
    log_message "✓ Updated to commit: $new_commit" "$GREEN"
    
    # Update dependencies (UV-only flow)
    log_message "  Installing/updating dependencies with uv..." "$BLUE"
    
    local venv_path="$instance_dir/venv"
    if [ -d "$venv_path" ]; then
        if [ -f "$instance_dir/requirements.txt" ]; then
            local activate="source $venv_path/bin/activate"
            sudo bash -c "$activate && uv pip install -r $instance_dir/requirements.txt" 2>&1 | tee -a "$UPDATE_LOG"
            
            if [ $? -eq 0 ]; then
                log_message "✓ Dependencies updated (uv)" "$GREEN"
            else
                log_message "⚠ Dependency update had issues (non-critical)" "$YELLOW"
            fi
        else
            log_message "⚠ requirements.txt not found, skipping dependency update" "$YELLOW"
        fi
    else
        log_message "⚠ Virtual environment not found, skipping dependency update" "$YELLOW"
    fi
    
    # Merge .env file changes
    log_message "  Merging .env configuration..." "$BLUE"
    merge_env_file "$instance_dir" "$backup_dir"
    
    # Run migration script (UV-only flow)
    if [ -d "$instance_dir/upgrade" ] && [ -f "$instance_dir/upgrade/migrate_all.py" ]; then
        log_message "  Running migrations with uv..." "$BLUE"
        sudo bash -c "cd $instance_dir/upgrade && uv run migrate_all.py" 2>&1 | tee -a "$UPDATE_LOG"
        if [ $? -eq 0 ]; then
            log_message "✓ Migrations completed" "$GREEN"
        else
            log_message "⚠ Migration script reported issues (non-critical)" "$YELLOW"
        fi
    else
        log_message "⚠ Migration script not found, skipping" "$YELLOW"
    fi

    # Restart service
    if [ "$was_running" = true ]; then
        log_message "  Restarting service: $service_name" "$BLUE"
        sudo systemctl start "$service_name"
        check_status "Failed to start service" || return 1
        
        # Wait for service to be ready
        sleep 3
        
        # Verify service is running
        if systemctl is-active --quiet "$service_name"; then
            log_message "✓ Service restarted successfully" "$GREEN"
        else
            log_message "❌ Service failed to restart!" "$RED"
            log_message "Backup available at: $backup_dir" "$YELLOW"
            return 1
        fi
    fi
    
    log_message "✓ Instance updated successfully" "$GREEN"
    log_message "  Backup preserved at: $backup_dir" "$BLUE"
    return 0
}

# Function to dry-run update (show what would be updated)
dry_run_update() {
    local instance_name="$1"
    local instance_dir="$BASE_DIR/$instance_name"
    
    log_message "\n--- Dry-run: $instance_name ---" "$BLUE"
    
    if [ ! -d "$instance_dir/.git" ]; then
        log_message "❌ Not a git repository" "$RED"
        return 1
    fi
    
    cd "$instance_dir"
    
    log_message "Current status:" "$BLUE"
    sudo git status 2>&1 | head -10 | tee -a "$UPDATE_LOG"
    
    log_message "\nFetching remote changes..." "$BLUE"
    sudo git fetch origin 2>&1 | tail -2 | tee -a "$UPDATE_LOG"
    
    log_message "\nChanges available:" "$BLUE"
    sudo git log --oneline HEAD..origin/main -20 2>/dev/null | tee -a "$UPDATE_LOG"
    
    if sudo git diff --quiet HEAD origin/main; then
        log_message "\n✓ Already up to date" "$GREEN"
    else
        log_message "\n⚠ Updates available from remote" "$YELLOW"
    fi
}

# Interactive menu
show_menu() {
    echo ""
    log_message "=== UPDATE OPTIONS ===" "$BLUE"
    
    # Get list of instances
    local instances=($(find "$BASE_DIR" -maxdepth 1 -type d -name "openalgo[0-9]*" -printf "%f\n" 2>/dev/null | sort))
    
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
    echo "$i) 🚀 Update ALL instances"
    echo "$((i+1))) Dry-run check (show available updates)"
    echo "$((i+2))) Exit"
    echo ""
    
    local total_options=$((i+2))
    read -p "Select option [1-$total_options]: " choice
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > total_options )); then
        log_message "Invalid choice" "$RED"
        return 1
    fi
    
    if [ $choice -eq $i ]; then
        update_all_instances
    elif [ $choice -eq $((i+1)) ]; then
        show_dry_run_menu
    elif [ $choice -eq $((i+2)) ]; then
        exit 0
    else
        local selected="${instances[$((choice - 1))]}"
        update_instance "$selected"
    fi
}

# Update all instances
update_all_instances() {
    log_message "Starting batch update of all instances..." "$BLUE"
    
    local instances=($(find "$BASE_DIR" -maxdepth 1 -type d -name "openalgo[0-9]*" -printf "%f\n" 2>/dev/null | sort))
    local success=0
    local failed=0
    
    for instance in "${instances[@]}"; do
        if update_instance "$instance"; then
            ((success++))
        else
            ((failed++))
        fi
        sleep 2
    done
    
    log_message "\n╔════════════════════════════════════╗" "$BLUE"
    log_message "║   BATCH UPDATE COMPLETE            ║" "$BLUE"
    log_message "╚════════════════════════════════════╝" "$BLUE"
    
    log_message "Successfully updated: $success instance(s)" "$GREEN"
    if [ $failed -gt 0 ]; then
        log_message "Failed to update: $failed instance(s)" "$RED"
    fi
}

# Dry-run menu
show_dry_run_menu() {
    echo ""
    log_message "=== DRY-RUN OPTIONS ===" "$BLUE"
    
    local instances=($(find "$BASE_DIR" -maxdepth 1 -type d -name "openalgo[0-9]*" -printf "%f\n" 2>/dev/null | sort))
    
    if [ ${#instances[@]} -eq 0 ]; then
        return 1
    fi
    
    echo "Select instance to check:"
    local i=1
    for inst in "${instances[@]}"; do
        echo "$i) $inst"
        ((i++))
    done
    echo "$i) Check ALL instances"
    echo ""
    
    read -p "Select option [1-$i]: " choice
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > i )); then
        log_message "Invalid choice" "$RED"
        return 1
    fi
    
    if [ $choice -eq $i ]; then
        for instance in "${instances[@]}"; do
            dry_run_update "$instance"
            echo ""
        done
    else
        local selected="${instances[$((choice - 1))]}"
        dry_run_update "$selected"
    fi
}

# Rollback to backup
rollback_instance() {
    local backup_dir="$1"
    local instance_name="$2"
    local instance_dir="$BASE_DIR/$instance_name"
    local instance_num=$(echo "$instance_name" | sed 's/[^0-9]*//g')
    local service_name
    service_name=$(get_service_name "$instance_dir" "$instance_num")
    
    if [ ! -d "$backup_dir" ]; then
        log_message "❌ Backup directory not found: $backup_dir" "$RED"
        return 1
    fi
    
    log_message "\n⚠ Rolling back $instance_name from backup..." "$YELLOW"
    
    # Stop service
    if systemctl is-active --quiet "$service_name"; then
        log_message "  Stopping service..." "$BLUE"
        sudo systemctl stop "$service_name"
        sleep 2
    fi
    
    # Restore .env if available
    if [ -f "$backup_dir/.env" ]; then
        log_message "  Restoring .env..." "$BLUE"
        sudo cp "$backup_dir/.env" "$instance_dir/"
    fi
    
    # Restore database if available
    if [ -d "$backup_dir/db" ]; then
        log_message "  Restoring database..." "$BLUE"
        sudo rm -rf "$instance_dir/db"
        sudo cp -r "$backup_dir/db" "$instance_dir/"
        sudo chown -R www-data:www-data "$instance_dir/db"
    fi
    
    # Restart service
    log_message "  Restarting service..." "$BLUE"
    sudo systemctl start "$service_name"
    sleep 2
    
    if systemctl is-active --quiet "$service_name"; then
        log_message "✓ Rollback completed successfully" "$GREEN"
        return 0
    else
        log_message "❌ Service failed to restart after rollback" "$RED"
        return 1
    fi
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
    echo "                      UPDATE UTILITY                                   "
    echo -e "${NC}"
    
    # Check if base directory exists
    if [ ! -d "$BASE_DIR" ]; then
        log_message "❌ Base directory not found: $BASE_DIR" "$RED"
        exit 1
    fi
    
    # Show menu if no arguments
    if [ $# -eq 0 ]; then
        show_menu
    else
        local command="$1"
        case $command in
            update-all) update_all_instances ;;
            dry-run) show_dry_run_menu ;;
            rollback)
                if [ -z "$2" ] || [ -z "$3" ]; then
                    log_message "Usage: $0 rollback <backup_dir> <instance_name>" "$YELLOW"
                    exit 1
                fi
                rollback_instance "$2" "$3"
                ;;
            *)
                if [ -d "$BASE_DIR/$command" ]; then
                    update_instance "$command"
                else
                    log_message "Usage: $0 [update-all|dry-run|rollback BACKUP_DIR INSTANCE|INSTANCE_NAME]" "$YELLOW"
                    exit 1
                fi
                ;;
        esac
    fi
    
    log_message "\nUpdate log saved to: $UPDATE_LOG" "$BLUE"
}

main "$@"
