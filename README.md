# OpenAlgo Instance Management Scripts

A collection of simplified bash scripts for managing OpenAlgo trading platform instances on Ubuntu/Debian servers.

## Overview

These scripts automate the installation, configuration, and maintenance of one or more OpenAlgo instances running on a single server. Each instance can be configured for a different broker and domain, with independent Flask ports, WebSocket endpoints, and databases.

## Scripts

### `quick-setup.sh`
**Single instance quick setup with 4GB swap**

Automated setup for a single OpenAlgo instance in one command. Includes all necessary components:
- System package updates
- 4GB swap configuration
- OpenAlgo installation and dependencies
- SSL certificate (Let's Encrypt)
- Nginx reverse proxy
- Systemd service
- Firewall configuration

**Usage:**
```bash
chmod +x quick-setup.sh
sudo ./quick-setup.sh
```

**Interactive prompts for:**
- Domain/subdomain
- Broker selection
- API credentials
- Market data credentials (if XTS broker)

**Best for:** Single instance deployments, simple setups, testing

### `multi-install.sh`
**Multi-instance installation and configuration**

Automates the complete setup of multiple OpenAlgo instances with:
- System package installation and firewall configuration
- Interactive prompts for domain, broker, and API credentials per instance
- Nginx SSL certificate generation via Let's Encrypt
- Individual systemd services per instance
- Database and session cookie isolation per instance

**Usage:**
```bash
chmod +x multi-install.sh
sudo ./multi-install.sh
```

**Best for:** Multiple instances, production deployments, advanced setups

**Features:**
- Supports up to 30 different brokers (fivepaisa, zerodha, angel, etc.)
- Special handling for XTS-based brokers (compositedge, ibulls, wisdom, etc.) that require market data credentials
- Automatic instance numbering (openalgo1, openalgo2, etc.) to avoid conflicts
- Unique ports for each instance:
  - Flask: 5000 + instance number
  - WebSocket: 8765 + instance number
  - ZMQ: 5555 + instance number
- Comprehensive logging to `logs/install_multi_TIMESTAMP.log`

### `update_swap_4gb.sh`
**Configure 4GB swap memory (fixed size)**

Sets up a fixed 4GB swap space to prevent out-of-memory issues, especially useful for broker authentication processes that can consume significant memory.

**Usage:**
```bash
chmod +x update_swap_4gb.sh
sudo ./update_swap_4gb.sh
```

### `oa-configure-swap.sh`
**Configure custom swap memory size**

Flexible swap configuration utility allowing users to specify any swap size from 1GB to 512GB. Includes disk space validation, current swap inspection, and safe reconfiguration.

**Features:**
- Interactive mode (prompts for size) or command-line argument
- Input validation (1-512 GB range)
- Disk space availability check with 10% buffer
- Displays current swap configuration and filesystem usage
- Shows recommended swap sizes (conservative and moderate)
- Confirmation prompt before changes
- Comprehensive logging with status messages

**Usage:**
```bash
chmod +x oa-configure-swap.sh

# Interactive mode
sudo ./oa-configure-swap.sh

# Command-line mode (no prompts)
sudo ./oa-configure-swap.sh 8
```

**Examples:**
```bash
# Create 8GB swap
sudo ./oa-configure-swap.sh 8

# Create 16GB swap
sudo ./oa-configure-swap.sh 16

# Interactive - prompts user for size
sudo ./oa-configure-swap.sh
```

### `make-executable.sh`
**Make all repository scripts executable**

Utility script that finds and makes all shell scripts in the repository executable in one command. Useful during initial setup or when scripts are added.

**Features:**
- Automatically finds all `.sh` files in the repository
- Skips already executable scripts
- Reports success/failure for each script
- Provides summary of changes
- Lists all available executable scripts

**Usage:**
```bash
chmod +x make-executable.sh
sudo ./make-executable.sh
```

**Output includes:**
- ✓ Successfully made executable
- ✓ Already executable (skipped)
- ✗ Failed to make executable (if any)
- List of all available executable scripts

### `oa-restart.sh`
**Restart OpenAlgo instances (manual)**

Interactive menu to restart individual instances or all instances at once.

**Usage:**
```bash
sudo ./oa-restart.sh
```

**Options:**
- Select specific instance to restart
- Select "Restart ALL instances"
- Auto-reloads Nginx after restart
- Cleans per-instance log files before each restart

### `setup-daily-restart.sh`
**Setup automatic daily restart of all instances at 8 AM IST**

Configures a cron job to automatically restart all OpenAlgo instances every day at 8:00 AM IST (India Standard Time). Creates restart script and log file for monitoring.

**Features:**
- Automated setup of cron job
- Restarts all instances sequentially
- Logs all restart activities
- Cleans per-instance log files before each restart
- Verifies system timezone
- Easy modification of restart time
- Provides monitoring commands

**Usage:**
```bash
sudo ./setup-daily-restart.sh
```

**What it does:**
- Creates automated restart script at `/usr/local/bin/openalgo-daily-restart.sh`
- Sets up cron job for 8:00 AM daily
- Creates log file at `/var/log/openalgo-daily-restart.log`
- Checks and optionally sets timezone to IST
- Provides commands to manage/modify the cron job

**To change restart time:**
```bash
sudo crontab -e
# Change the first two numbers (hour minute)
# Format: minute hour * * * /usr/local/bin/openalgo-daily-restart.sh
# Examples:
#   0 8   = 8:00 AM
#   30 7  = 7:30 AM
#   0 9   = 9:00 AM
```

**To view restart logs:**
```bash
sudo tail -f /var/log/openalgo-daily-restart.log
```

**To remove the cron job:**
```bash
sudo crontab -r
```

### `api-manager.sh`
**Simple interactive API setup and management (Recommended)**

Simple, robust menu-driven script with proper input handling for all API operations.

**Features:**
- Install API from current directory
- Setup systemd service (auto-start on boot)
- Configure firewall rules (UFW)
- Manage service (start, stop, restart, status)
- View API logs
- Verify API is working
- Simple, clean menu interface
- Proper input handling (no sudo stdin issues)

**Usage:**
```bash
sudo ./api-manager.sh
```

**Menu Options:**
1. Install & Setup API - Copies script and configures systemd
2. Verify API Status - Checks all components
3. Manage Service - Control service (start/stop/restart)
4. View Logs - Recent or live logs
5. Exit

**Quick Setup:**
```bash
sudo ./api-manager.sh
# Select option 1 (Install & Setup API)
# Select option 4 (Setup Everything)
```

This is the recommended script to use for first-time setup and management.

### `install-api.sh`
**Install OpenAlgo REST API (Legacy)**

Installs the REST API script to the system and verifies it's working.

**Features:**
- Copies API script to `/usr/local/bin/`
- Verifies Python3 is installed
- Tests API functionality
- Provides next steps for setup

**Usage:**
```bash
sudo ./install-api.sh
```

This needs to be run only once before using other API scripts.

### `setup-api.sh`
**Unified API setup, verification, and management**

Comprehensive interactive script that handles all API setup, configuration, verification, and management tasks in one place. Auto-installs API if needed.

**Features:**
- Auto-install API if not already installed
- Setup API as systemd service (auto-start on boot)
- Verify API is running and accessible
- Configure remote restart methods (SSH & REST API)
- Manage service (status, restart, stop, start)
- View API logs
- Interactive menu with all options
- Auto-fixes common issues (firewall, processes, etc.)

**Usage:**
```bash
sudo ./setup-api.sh
```

**Menu Options:**
1. Setup API as Systemd Service - Install and configure systemd service
2. Verify API is Running - Check all components and auto-fix issues
3. Setup Remote Restart - Configure SSH and REST API access
4. Setup Everything - Run all setup options at once (recommended)
5. Manage Service - Status, restart, stop, start commands
6. View API Logs - View recent logs or follow live
7. Exit

**Quick Start (One Command):**
```bash
sudo ./setup-api.sh
# Select option 4 (Setup Everything)
# This will:
#   1. Install API if needed
#   2. Setup systemd service
#   3. Verify everything works
#   4. Configure SSH and REST API access
```

**Service Management:**
```bash
# Check status
sudo systemctl status openalgo-restart-api

# View live logs
sudo journalctl -u openalgo-restart-api -f

# Restart service
sudo systemctl restart openalgo-restart-api

# Stop service
sudo systemctl stop openalgo-restart-api
```

**Remote Restart Methods:**

Run `sudo ./setup-api.sh` and select option 3 to configure these methods:

**Method 1: SSH (Direct execution)**
```bash
# Trigger restart from remote machine
ssh root@<server_ip> sudo /usr/local/bin/openalgo-daily-restart.sh

# View logs
ssh root@<server_ip> tail -f /var/log/openalgo-daily-restart.log

# Check status
ssh root@<server_ip> systemctl status openalgo*
```

**Method 2: REST API (HTTP webhook) - Full Featured**

The REST API provides a complete web interface for managing instances:

**Web UI Dashboard (Recommended):**
```
http://<server_ip>:8888
```
- Interactive dashboard with all instance information
- **Instance Health Checks:**
  - Service status (Active/Inactive)
  - Flask port configuration
  - Database presence verification
- Click to restart/stop/start individual instances
- Bulk restart all instances
- Real-time status updates
- Auto-refresh every 30 seconds
- Summary showing total, running, and stopped instances

**REST API Endpoints:**

```bash
# === Restart Operations ===

# Restart ALL instances (POST)
curl -X POST http://<server_ip>:8888/api/restart-all

# Restart specific instance (POST)
curl -X POST http://<server_ip>:8888/api/restart-instance \
  -H "Content-Type: application/json" \
  -d '{"instance": "openalgo1"}'

# Stop specific instance (POST)
curl -X POST http://<server_ip>:8888/api/stop-instance \
  -H "Content-Type: application/json" \
  -d '{"instance": "openalgo1"}'

# Start specific instance (POST)
curl -X POST http://<server_ip>:8888/api/start-instance \
  -H "Content-Type: application/json" \
  -d '{"instance": "openalgo1"}'

# === Information Endpoints ===

# Get list of all instances (GET)
curl http://<server_ip>:8888/api/instances

# Get status of all instances (GET)
curl http://<server_ip>:8888/api/status

# Check API health (GET)
curl http://<server_ip>:8888/health

# Get detailed health of all instances (GET)
curl http://<server_ip>:8888/api/health
```

**API Endpoints Summary:**

**Instance Management:**
- `POST /api/restart-all` - Restart all instances
- `POST /api/restart-instance` - Restart specific instance (requires JSON body with "instance" field)
- `POST /api/stop-instance` - Stop specific instance
- `POST /api/start-instance` - Start specific instance

**Information & Health:**
- `GET /api/instances` - List all instances
- `GET /api/status` - Get status of all instances (active/inactive)
- `GET /api/health` - **Detailed health check of all instances** (status, port, database)
- `GET /health` - API server health check

**User Interface:**
- `GET /` or `/index.html` - Interactive web dashboard with health checks

**Example API Responses:**

Restart all response:
```json
{
  "status": "success",
  "message": "Restart triggered for all OpenAlgo instances",
  "timestamp": "2025-01-15 08:30:45.123456"
}
```

Restart specific instance response:
```json
{
  "status": "success",
  "message": "Restart triggered for openalgo1",
  "instance": "openalgo1",
  "timestamp": "2025-01-15 08:30:45.123456"
}
```

Status response:
```json
{
  "total_instances": 3,
  "instances": {
    "openalgo1": "active",
    "openalgo2": "active",
    "openalgo3": "inactive"
  },
  "timestamp": "2025-01-15 08:30:45.123456"
}
```

List instances response:
```json
[
  "openalgo1",
  "openalgo2",
  "openalgo3"
]
```

Health check response:
```json
{
  "total": 3,
  "instances": {
    "openalgo1": {
      "name": "openalgo1",
      "status": "active",
      "port": "5001",
      "database": true
    },
    "openalgo2": {
      "name": "openalgo2",
      "status": "active",
      "port": "5002",
      "database": true
    },
    "openalgo3": {
      "name": "openalgo3",
      "status": "inactive",
      "port": "5003",
      "database": true
    }
  },
  "timestamp": "2025-01-15 08:30:45.123456"
}
```

**Security considerations:**
- Use SSH keys instead of passwords
- Restrict SSH access via firewall
- Use VPN for remote access over internet
- Monitor logs for unauthorized access attempts

### `oa-uninstaller.sh`
**Remove OpenAlgo instances**

Interactive menu to remove individual instances or all instances with cleanup of:
- Systemd services
- Instance directories and databases
- Nginx configurations
- SSL certificates

**Usage:**
```bash
chmod +x oa-uninstaller.sh
sudo ./oa-uninstaller.sh
```

### `oa-clear-logs.sh`
**Clear all OpenAlgo logs**

Deletes per-instance log files and the daily restart log in one command.

**Usage:**
```bash
chmod +x oa-clear-logs.sh
sudo ./oa-clear-logs.sh
```

### `oa-health-check.sh`
**Monitor instance health and status**

Comprehensive health monitoring with multiple check categories:
- Service status and port availability (Flask, WebSocket, ZMQ)
- Configuration validation (.env, virtual environment, socket files)
- Database integrity and disk space usage
- Filesystem capacity warnings
- Recent error detection in logs
- HTTP/HTTPS endpoint connectivity
- File permissions and security
- System-wide checks (Nginx, firewall, swap, load average)

**Usage:**
```bash
chmod +x oa-health-check.sh
sudo ./oa-health-check.sh              # Interactive menu
sudo ./oa-health-check.sh all          # Check all instances
sudo ./oa-health-check.sh system       # System health only
sudo ./oa-health-check.sh openalgo1    # Check specific instance
```

**Exit codes:**
- `0` - All healthy
- `1` - Warnings detected
- `2` - Critical issues found

### `oa-backup.sh`
**Backup and restore instance data**

Flexible backup system with encryption support and restore capabilities:
- **Quick backup** - .env (encrypted), databases, nginx config, systemd service
- **Full backup** - Complete instance archive (excludes venv, excludes Python cache)
- **GPG encryption** - Encrypts sensitive `.env` files (requires passphrase on restore)
- **Restore** - Selective restore with current data preservation
- **Cleanup** - Automatic removal of backups older than retention period (default 30 days)

**Usage:**
```bash
chmod +x oa-backup.sh
sudo ./oa-backup.sh                    # Interactive menu
sudo ./oa-backup.sh single quick       # Single instance quick backup
sudo ./oa-backup.sh single full        # Single instance full backup
sudo ./oa-backup.sh all quick          # All instances quick backup
sudo ./oa-backup.sh all full           # All instances full backup
sudo ./oa-backup.sh restore            # Restore from backup
sudo ./oa-backup.sh list               # List available backups
sudo ./oa-backup.sh cleanup 30         # Clean backups older than 30 days
```

**Backup location:** Current directory (or specify custom path)

### `oa-update.sh`
**Update OpenAlgo instances with configuration preservation**

Smart update system that intelligently handles `.env` file changes:
- **Version-aware merging** - Uses `ENV_CONFIG_VERSION` to detect configuration changes
- **Selective merge** - Only updates `.env` when the version changes
- **Pre-update backup** - Automatic backup before any update
- **Dependency updates** - Installs/upgrades Python packages from requirements files
- **Service management** - Stops service during update, restarts after completion
- **Dry-run mode** - Preview available updates before applying
- **Rollback support** - Restore from pre-update backup if needed

**How it works:**
- OpenAlgo devs increment `ENV_CONFIG_VERSION` only when `.env` structure changes
- Bug fixes and code updates (same version) → `.env` untouched, fast restart
- Config changes (version bumped) → Intelligent merge preserves ports, credentials, broker, keys

**Usage:**
```bash
chmod +x oa-update.sh
sudo ./oa-update.sh                    # Interactive menu
sudo ./oa-update.sh openalgo1          # Update specific instance
sudo ./oa-update.sh update-all         # Update all instances
sudo ./oa-update.sh dry-run            # Preview available updates
sudo ./oa-update.sh rollback BACKUP_DIR openalgo1  # Rollback from backup
```

**Update log:** Saved to `/tmp/update_TIMESTAMP.log`

## Installation Requirements

- Ubuntu 20.04 LTS or later (Debian-based)
- Root/sudo access
- Domain names with DNS pointing to your server
- Broker API credentials for each instance

## Quick Start (Single Instance)

For a simple single instance setup with 4GB swap, use the quick-setup script:

```bash
sudo apt update && sudo apt install -y git
rm -rf Simplifyed-Scripts
git clone https://github.com/jabez4jc/Simplifyed-Scripts
cd Simplifyed-Scripts
chmod +x quick-setup.sh
sudo ./quick-setup.sh
```

This will:
- Update system packages
- Configure 4GB swap
- Clone OpenAlgo repository
- Install all dependencies
- Set up SSL certificate (Let's Encrypt)
- Create systemd service
- Configure Nginx
- Configure firewall

## Standard Installation Steps (Multiple Instances)

1. **System preparation:**
   ```bash
   sudo apt update && sudo apt install -y git nano
   sudo apt upgrade -y
   rm -rf Simplifyed-Scripts
   git clone https://github.com/jabez4jc/Simplifyed-Scripts
   cd Simplifyed-Scripts
   ```

2. **Make all scripts executable:**
   ```bash
   chmod +x make-executable.sh
   sudo ./make-executable.sh
   ```
   This will find and make all `.sh` scripts executable in the repository.

3. **Configure swap:**
   ```bash
   sudo ./update_swap_4gb.sh
   ```
   Or use custom size:
   ```bash
   sudo ./oa-configure-swap.sh
   ```

4. **Install OpenAlgo instances:**
   ```bash
   sudo ./multi-install.sh
   ```
   - Select number of instances
   - Provide domain, broker, and credentials for each
   - Script handles SSL, Nginx, and systemd services

## Instance Management

### View installed instances:
```bash
systemctl list-units 'openalgo*'
```

### Check instance status:
```bash
sudo systemctl status openalgo-<domain>
```

### View instance logs:
```bash
sudo journalctl -u openalgo-<domain> -f
```

### Restart specific instance:
```bash
sudo systemctl restart openalgo-<domain>
```

## Directory Structure

Each instance is located at: `/var/python/openalgo-flask/openalgo<N>/`

For new installs:
- Systemd service names use the domain: `openalgo-<domain>` (for example `openalgo-example-com`)
- A symlink is created for easy identification: `/var/python/openalgo-flask/openalgo-<domain> -> openalgo<N>`

- `.env` - Environment variables and broker credentials
- `app.py` - Flask application entry point
- `db/` - SQLite databases (openalgo, latency, logs)
- `strategies/` - User strategy files
- `keys/` - Sensitive key storage
- `venv/` - Python virtual environment

## Configuration Details

### Instance Isolation

Each instance has:
- Independent `.env` file with unique ports, credentials, and cookies
- Separate SQLite databases
- Unique session/CSRF cookie names
- Individual systemd service

### Broker Support

**REST-based brokers:**
fivepaisa, aliceblue, angel, definedge, dhan, dhan_sandbox, firstock, flattrade, fyers, groww, indmoney, kotak, motilal, mstock, paytm, pocketful, samco, shoonya, tradejini, upstox, zebu, zerodha

**XTS-based brokers** (require market data credentials):
fivepaisaxts, compositedge, ibulls, iifl, jainamxts, wisdom

### SSL/TLS

- Uses Let's Encrypt for free SSL certificates via Certbot
- Automatic renewal via systemd
- Nginx handles SSL termination and reverse proxy

## Security Notes

- Sensitive credentials (API keys) are stored in instance `.env` files
- File permissions restrict access to `www-data` user
- WebSocket and ZMQ ports are bound to localhost; external access only through Nginx
- Firewall configured to allow only SSH, HTTP, and HTTPS

## Logs

Installation logs are saved to `logs/install_multi_TIMESTAMP.log` for troubleshooting.

## Support

For issues with OpenAlgo itself, refer to the [OpenAlgo GitHub repository](https://github.com/marketcalls/openalgo).
