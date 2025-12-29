# OpenAlgo Instance Management Scripts

A collection of simplified bash scripts for managing OpenAlgo trading platform instances on Ubuntu/Debian servers.

## Overview

These scripts automate the installation, configuration, and maintenance of one or more OpenAlgo instances running on a single server. Each instance can be configured for a different broker and domain, with independent Flask ports, WebSocket endpoints, and databases.

## Scripts

### `multi-install.sh`
**Multi-instance installation and configuration**

Automates the complete setup of multiple OpenAlgo instances with:
- System package installation and firewall configuration
- Interactive prompts for domain, broker, and API credentials
- Nginx SSL certificate generation via Let's Encrypt
- Individual systemd services per instance
- Database and session cookie isolation per instance

**Usage:**
```bash
chmod +x multi-install.sh
sudo ./multi-install.sh
```

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
- Displays current swap configuration
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

### `oa-restart.sh`
**Restart OpenAlgo instances**

Interactive menu to restart individual instances or all instances at once.

**Usage:**
```bash
chmod +x oa-restart.sh
sudo ./oa-restart.sh
```

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

## Typical Installation Steps

1. **System preparation:**
   ```bash
   sudo apt update && sudo apt install -y nano
   sudo apt upgrade -y
   ```

2. **Configure swap (recommended):**
   ```bash
   chmod +x update_swap_4gb.sh
   sudo ./update_swap_4gb.sh
   ```

3. **Install OpenAlgo instances:**
   ```bash
   chmod +x multi-install.sh
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
sudo systemctl status openalgo<N>
```

### View instance logs:
```bash
sudo journalctl -u openalgo<N> -f
```

### Restart specific instance:
```bash
sudo systemctl restart openalgo<N>
```

## Directory Structure

Each instance is located at: `/var/python/openalgo-flask/openalgo<N>/`

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
