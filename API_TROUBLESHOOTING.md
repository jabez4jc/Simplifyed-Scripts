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

## Cloud Platform Firewall Rules

**Critical Issue:** If your servers are on a cloud platform (GCP, AWS, Azure), you MUST configure firewall rules in the cloud console. OS-level firewall rules are NOT enough.

### GCP (Google Cloud Platform) - REQUIRED

Even if UFW is inactive, you MUST allow port 8888 in GCP firewall:

**Via GCP Console:**
1. Go to VPC Network > Firewall rules
2. Create ingress rule:
   - Name: `allow-openalgo-8888`
   - Direction: Ingress
   - Action: Allow
   - Protocols: TCP port 8888
   - Source IP ranges: `0.0.0.0/0` (or specific IPs)

**Via gcloud CLI:**
```bash
gcloud compute firewall-rules create allow-openalgo-8888 \
    --allow=tcp:8888 \
    --source-ranges=0.0.0.0/0
```

**To target specific instances (recommended):**
```bash
# Create rule with target tags
gcloud compute firewall-rules create allow-openalgo-8888 \
    --allow=tcp:8888 \
    --target-tags=openalgo

# Tag your instances
gcloud compute instances add-tags INSTANCE_NAME \
    --tags=openalgo \
    --zone=us-central1-a
```

### AWS (Amazon Web Services) - REQUIRED

Configure Security Groups for each instance:

1. Go to EC2 Dashboard
2. Select Security Groups
3. Find the security group attached to your instance
4. Edit Inbound Rules
5. Add rule:
   - Type: Custom TCP Rule
   - Protocol: TCP
   - Port Range: 8888
   - Source: 0.0.0.0/0 (or specific IPs)
   - Description: OpenAlgo API

### Azure (Microsoft Azure) - REQUIRED

Configure Network Security Groups:

1. Go to Virtual Machines
2. Select your VM
3. Go to Settings > Networking
4. Add inbound port rule:
   - Source: Any (or specific IPs)
   - Source port ranges: *
   - Destination: Any
   - Destination port ranges: 8888
   - Protocol: TCP
   - Action: Allow
   - Priority: (lower number = higher priority)

## Diagnosis Scripts

Run these scripts to identify the issue:

### Test Local Connectivity
```bash
sudo ./test-api-remote.sh
```
Tests localhost, local IP, port binding, and firewall status.

### Configure OS Firewall
```bash
sudo ./configure-api-firewall.sh
```
Handles UFW, iptables, firewalld, and detects cloud platform.

### Compare Working vs Non-Working Servers
```bash
# Requires SSH access to servers
sudo ./compare-server-setup.sh
```
Compares configuration between working and failing servers.

## Common Issues by Cloud Platform

### GCP: "Connection refused" despite API running

**Cause:** GCP Firewall rule not created for port 8888

**Solution:** Create firewall rule in GCP Console (see above)

**Verify:**
```bash
# From GCP Console, list firewall rules
gcloud compute firewall-rules list --filter="allow-openalgo*"

# Check if rule allows your source IP
gcloud compute firewall-rules describe allow-openalgo-8888
```

### AWS: "Connection timed out"

**Cause:** Security Group doesn't allow inbound TCP 8888

**Solution:** Add inbound rule to Security Group (see above)

**Verify:**
```bash
# List security group rules
aws ec2 describe-security-groups --group-ids sg-xxxxxxxx
```

### Azure: "Connection refused"

**Cause:** NSG inbound rule doesn't allow port 8888

**Solution:** Add inbound rule to Network Security Group (see above)

**Verify:**
```bash
# List NSG rules
az network nsg rule list \
    --resource-group myResourceGroup \
    --nsg-name myNSG
```

## Support

If issues persist:

1. Verify you're on a cloud platform that blocks traffic by default
2. Create the appropriate cloud firewall rule (GCP/AWS/Azure)
3. Run `sudo ./configure-api-firewall.sh` to set up OS-level firewall
4. Run `sudo ./test-api-remote.sh` to verify local binding
5. Wait 1-2 minutes for cloud firewall rule to propagate
6. Test with: `curl -v http://SERVER_IP:8888/health`
7. Check `/tmp/api.log` for application errors
8. Check `sudo journalctl -u openalgo-restart-api -f` for service logs
