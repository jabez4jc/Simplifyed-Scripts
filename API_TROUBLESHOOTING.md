# OpenAlgo REST API - Troubleshooting Guide

## Issue: "Address already in use" on port 8888

This error occurs when the port 8888 is still occupied by an old or hung API process.

### Quick Fix (Recommended)

Run the new restart script which handles all cleanup methods:

```bash
chmod +x restart-api-service.sh
sudo ./restart-api-service.sh
```

This script will:
1. Kill existing API processes by name
2. Kill process by port using multiple methods (fuser, ss, netstat)
3. Verify port 8888 is free
4. Start the API service
5. Verify API is responding

### Manual Troubleshooting

If the quick fix doesn't work, try these steps:

#### Step 1: Identify the process on port 8888

**Method 1: Using ss (modern systems)**
```bash
sudo ss -tlnp | grep 8888
```

**Method 2: Using netstat (all systems)**
```bash
sudo netstat -tlnp | grep 8888
```

**Method 3: Using fuser**
```bash
sudo fuser 8888/tcp
```

#### Step 2: Kill the process

**Method 1: Kill by process name (recommended)**
```bash
sudo pkill -9 -f "python3.*openalgo-restart-api"
```

**Method 2: Kill by port using fuser (if available)**
```bash
sudo fuser -k 8888/tcp
```

**Method 3: Kill by port using PID from ss**
```bash
# Get PID from ss output and kill it
PID=$(sudo ss -tlnp | grep 8888 | awk '{print $NF}' | cut -d'/' -f1)
sudo kill -9 $PID
```

**Method 4: Kill by port using PID from netstat**
```bash
# Get PID from netstat output and kill it
PID=$(sudo netstat -tlnp | grep 8888 | awk '{print $NF}' | cut -d'/' -f1)
sudo kill -9 $PID
```

#### Step 3: Verify port is free

```bash
sudo ss -tlnp | grep 8888
# Should show: no results

# Or use netstat
sudo netstat -tlnp | grep 8888
# Should show: no results
```

#### Step 4: Start API manually

```bash
sudo python3 /usr/local/bin/openalgo-restart-api.py 8888
```

If it starts successfully, you'll see:
```
OpenAlgo API running on 0.0.0.0:8888
```

Then access it at: `http://localhost:8888`

#### Step 5: Restart systemd service (if installed)

If the API was installed as a systemd service:

```bash
sudo systemctl daemon-reload
sudo systemctl restart openalgo-restart-api
sudo systemctl status openalgo-restart-api
```

### Check service logs

```bash
sudo journalctl -u openalgo-restart-api -n 20 -f
```

### Verify API is accessible

```bash
# From the same server
curl http://localhost:8888/health

# From a remote machine (replace IP)
curl http://your-server-ip:8888/health
```

### Check firewall rules

If the port shows as listening but you can't access from remote:

```bash
# Check UFW firewall
sudo ufw status
sudo ufw allow 8888

# Check iptables
sudo iptables -L -n | grep 8888

# Add iptables rule if needed
sudo iptables -A INPUT -p tcp --dport 8888 -j ACCEPT
```

## Common Issues and Solutions

### Issue: Port shows as listening but not accessible from remote IP

**Cause:** API bound to localhost (127.0.0.1) instead of 0.0.0.0

**Solution:** Check that openalgo-restart-api.py has this line:
```python
server = socketserver.TCPServer(("0.0.0.0", PORT), RestartHandler)
```

NOT this:
```python
server = socketserver.TCPServer(("", PORT), RestartHandler)  # Wrong
server = socketserver.TCPServer(("127.0.0.1", PORT), RestartHandler)  # Wrong
```

### Issue: "No such file or directory" for openalgo-restart-api.py

**Cause:** File not installed to correct location

**Solution:** Ensure file is at `/usr/local/bin/openalgo-restart-api.py`:
```bash
sudo cp openalgo-restart-api.py /usr/local/bin/
sudo chmod +x /usr/local/bin/openalgo-restart-api.py
```

### Issue: Python3 not found

**Cause:** Python3 not installed

**Solution:**
```bash
sudo apt update
sudo apt install -y python3
python3 --version
```

### Issue: Permission denied starting service

**Cause:** Need to run with sudo

**Solution:** Always use:
```bash
sudo python3 /usr/local/bin/openalgo-restart-api.py 8888
sudo systemctl restart openalgo-restart-api
```

## Debugging Steps

### Enable verbose logging

Check the API logs while it's running:

**If running in foreground:**
```bash
sudo python3 /usr/local/bin/openalgo-restart-api.py 8888
```

**If running as systemd service:**
```bash
sudo journalctl -u openalgo-restart-api -f
```

**If running in background:**
```bash
tail -f /tmp/api.log
```

### Test API endpoints

```bash
# Health check
curl http://localhost:8888/health

# Get instances
curl http://localhost:8888/api/instances

# Get status
curl http://localhost:8888/api/status

# Web UI
curl -v http://localhost:8888/
```

### Check if API accepts connections

```bash
# From the server
netstat -tlnp | grep 8888
ss -tlnp | grep 8888

# Try telnet
telnet localhost 8888
# Press Ctrl+C to exit

# Try nc (netcat)
nc -zv localhost 8888
```

## Still Not Working?

### Collect diagnostic information

Run the diagnostic script:
```bash
chmod +x diagnose-api.sh
sudo ./diagnose-api.sh
```

This will check:
- Python3 installation
- API script location and permissions
- Systemd service status
- Port availability
- Firewall rules
- API connectivity
- Automatic fixes for common issues

### Check system resources

```bash
# Check disk space
df -h

# Check memory
free -h

# Check running processes
ps aux | grep python3
ps aux | grep openalgo

# Check port status
sudo netstat -tlnp
sudo ss -tlnp
```

### Review installation

Verify the API script was installed correctly:

```bash
# Check file exists and is executable
ls -la /usr/local/bin/openalgo-restart-api.py

# Check file contents (look for "0.0.0.0" in server binding)
grep "TCPServer" /usr/local/bin/openalgo-restart-api.py
```

## Support

If issues persist:

1. Run `diagnose-api.sh` and save output
2. Check `/tmp/api.log` for error details
3. Check `sudo journalctl -u openalgo-restart-api -n 50` for service logs
4. Verify firewall allows port 8888: `sudo ufw allow 8888`
5. Ensure no other service is using port 8888: `sudo ss -tlnp | grep 8888`
