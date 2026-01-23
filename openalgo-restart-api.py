#!/usr/bin/env python3
"""
OpenAlgo REST API with Web UI - Simplified Version
"""

import http.server
import socketserver
import subprocess
import json
import sys
import os
import sqlite3
from threading import Thread
from urllib.parse import urlparse, parse_qs
from datetime import datetime

PORT = 8888

class RestartHandler(http.server.BaseHTTPRequestHandler):
    def _db_has_auth_table(self, db_file):
        try:
            conn = sqlite3.connect(db_file)
            cur = conn.cursor()
            cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='auth'")
            found = cur.fetchone() is not None
            conn.close()
            return found
        except Exception:
            return False

    def _get_auth_db_file(self, instance):
        inst_path = f"/var/python/openalgo-flask/{instance}"
        instance_num = instance.replace('openalgo', '')
        db_dir = f"{inst_path}/db"
        candidates = []

        if instance_num.isdigit():
            candidates.append(f"{db_dir}/openalgo{instance_num}.db")
        candidates.append(f"{db_dir}/openalgo.db")
        candidates.append(f"{db_dir}/auth.db")

        for path in candidates:
            if os.path.exists(path) and self._db_has_auth_table(path):
                return path

        if os.path.isdir(db_dir):
            for entry in os.scandir(db_dir):
                if entry.is_file() and entry.name.endswith(".db"):
                    if self._db_has_auth_table(entry.path):
                        return entry.path
        return None

    def _read_auth_status(self, instance):
        db_file = self._get_auth_db_file(instance)

        if not db_file:
            return False, "Auth database not found"

        try:
            conn = sqlite3.connect(db_file)
            cur = conn.cursor()
            row = None
            for query in (
                "SELECT is_revoked, auth, feed_token, broker, name FROM auth ORDER BY id DESC LIMIT 1",
                "SELECT is_revoked, auth, feed_token, broker, name FROM auth ORDER BY rowid DESC LIMIT 1",
            ):
                try:
                    cur.execute(query)
                    row = cur.fetchone()
                    break
                except Exception:
                    continue
            conn.close()

            if not row:
                return False, "No auth record found"

            is_revoked, auth, feed_token, broker, name = row
            auth_blank = auth is None or str(auth).strip() == ""
            feed_blank = feed_token is None or str(feed_token).strip() == ""
            broker_blank = broker is None or str(broker).strip() == ""
            name_blank = name is None or str(name).strip() == ""

            if is_revoked == 1:
                return False, "Auth revoked", broker, name
            if is_revoked == 0 and (auth_blank or feed_blank or broker_blank):
                return False, "Auth fields missing", broker, name
            return True, None, broker, name
        except Exception as e:
            return False, f"Auth check failed: {e}", None, None
    def _service_name(self, instance):
        """Map instance directory to systemd service name."""
        env_file = f"/var/python/openalgo-flask/{instance}/.env"
        domain = None
        if os.path.exists(env_file):
            with open(env_file, 'r') as f:
                for line in f:
                    if line.startswith('DOMAIN='):
                        domain = line.split('=', 1)[1].strip().strip("'\"")
                        break
        if domain:
            return f"openalgo-{domain.replace('.', '-')}"
        return instance
    
    def do_GET(self):
        """Handle GET requests"""
        if self.path == '/' or self.path == '/index.html':
            self.serve_web_ui()
        elif self.path == '/api/instances':
            self.handle_instances()
        elif self.path == '/api/status':
            self.handle_status()
        elif self.path == '/api/health':
            self.handle_instances_health()
        elif self.path == '/health':
            self.handle_health()
        elif self.path.startswith('/api/logs/'):
            instance = self.path.split('/api/logs/')[1].strip('/')
            if instance:
                self.handle_instance_logs(instance)
            else:
                self.send_json({"error": "Missing instance parameter"}, 400)
        elif self.path.startswith('/api/broker-status/'):
            instance = self.path.split('/api/broker-status/')[1].strip('/')
            if instance:
                self.handle_broker_status(instance)
            else:
                self.send_json({"error": "Missing instance parameter"}, 400)
        else:
            self.send_json({"error": "Not found"}, 404)
    
    def do_POST(self):
        """Handle POST requests"""
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode('utf-8') if content_length > 0 else ''
        
        try:
            data = json.loads(body) if body else {}
        except:
            self.send_json({"error": "Invalid JSON"}, 400)
            return
        
        if self.path == '/api/restart-all':
            self.handle_restart_all()
        elif self.path == '/api/restart-instance':
            instance = data.get('instance', '')
            if instance:
                self.handle_restart_instance(instance)
            else:
                self.send_json({"error": "Missing instance parameter"}, 400)
        elif self.path == '/api/stop-instance':
            instance = data.get('instance', '')
            if instance:
                self.handle_stop_instance(instance)
            else:
                self.send_json({"error": "Missing instance parameter"}, 400)
        elif self.path == '/api/start-instance':
            instance = data.get('instance', '')
            if instance:
                self.handle_start_instance(instance)
            else:
                self.send_json({"error": "Missing instance parameter"}, 400)
        elif self.path == '/api/reboot-server':
            self.handle_reboot_server()
        else:
            self.send_json({"error": "Not found"}, 404)
    
    def handle_instances(self):
        """Get list of instances"""
        try:
            base_dir = "/var/python/openalgo-flask"
            instances = []
            if os.path.isdir(base_dir):
                for entry in os.scandir(base_dir):
                    if entry.is_dir(follow_symlinks=False) and entry.name.startswith("openalgo"):
                        suffix = entry.name[8:]
                        if suffix.isdigit():
                            instances.append(entry.name)
            self.send_json(sorted(instances))
        except Exception as e:
            self.send_json({"error": str(e)}, 500)
    
    def handle_status(self):
        """Get status of all instances"""
        try:
            base_dir = "/var/python/openalgo-flask"
            instances = []
            if os.path.isdir(base_dir):
                for entry in os.scandir(base_dir):
                    if entry.is_dir(follow_symlinks=False) and entry.name.startswith("openalgo"):
                        suffix = entry.name[8:]
                        if suffix.isdigit():
                            instances.append(entry.name)
            
            status = {"total": len(instances), "instances": {}, "timestamp": str(datetime.now())}
            
            for inst in instances:
                try:
                    service_name = self._service_name(inst)
                    result = subprocess.run(
                        f"systemctl is-active {service_name}",
                        shell=True, capture_output=True, text=True, timeout=2
                    )
                    status["instances"][inst] = result.stdout.strip()
                except:
                    status["instances"][inst] = "unknown"
            
            self.send_json(status)
        except Exception as e:
            self.send_json({"error": str(e)}, 500)
    
    def handle_instances_health(self):
        """Get detailed health status of all instances"""
        try:
            base_dir = "/var/python/openalgo-flask"
            instances = []
            if os.path.isdir(base_dir):
                for entry in os.scandir(base_dir):
                    if entry.is_dir(follow_symlinks=False) and entry.name.startswith("openalgo"):
                        suffix = entry.name[8:]
                        if suffix.isdigit():
                            instances.append(entry.name)
            
            health = {"total": len(instances), "instances": {}, "timestamp": str(datetime.now())}
            
            for inst in instances:
                health["instances"][inst] = self._get_instance_health(inst)
            
            self.send_json(health)
        except Exception as e:
            self.send_json({"error": str(e)}, 500)
    
    def handle_instance_logs(self, instance):
        """Get last 100 lines of logs for an instance"""
        try:
            service_name = self._service_name(instance)
            result = subprocess.run(
                f"sudo journalctl -u {service_name} -n 100 --no-pager",
                shell=True, capture_output=True, text=True, timeout=5
            )
            logs = result.stdout.strip().split('\n') if result.stdout.strip() else []
            self.send_json({
                "instance": instance,
                "logs": logs,
                "count": len(logs),
                "timestamp": str(datetime.now())
            })
        except Exception as e:
            self.send_json({
                "instance": instance,
                "logs": [],
                "error": str(e),
                "timestamp": str(datetime.now())
            }, 500)

    def handle_broker_status(self, instance):
        """Get broker authentication status for an instance"""
        try:
            inst_path = f"/var/python/openalgo-flask/{instance}"
            env_file = f"{inst_path}/.env"

            broker = None
            redirect_url = None

            # Extract broker from .env
            if os.path.exists(env_file):
                with open(env_file, 'r') as f:
                    for line in f:
                        if 'REDIRECT_URL' in line and '=' in line:
                            redirect_url = line.split('=', 1)[1].strip().strip("'\"")
                            # Extract broker from URL: https://domain.com/broker/callback
                            import re
                            match = re.search(r'/([^/]+)/callback', redirect_url)
                            if match:
                                broker = match.group(1)
                            break

            authenticated, last_error, broker_db, name_db = self._read_auth_status(instance)
            error_timestamp = None

            self.send_json({
                "instance": instance,
                "broker": broker_db or broker,
                "name": name_db,
                "authenticated": authenticated,
                "last_error": last_error,
                "error_timestamp": error_timestamp,
                "requires_login": not authenticated,
                "timestamp": str(datetime.now())
            })
        except Exception as e:
            self.send_json({
                "instance": instance,
                "error": str(e),
                "timestamp": str(datetime.now())
            }, 500)

    def _get_instance_health(self, instance):
        """Get detailed health info for a single instance"""
        health = {"name": instance, "status": "unknown", "port": None, "database": False, "broker": None, "domain": None, "auth_name": None, "session_valid": True}

        try:
            service_name = self._service_name(instance)
            result = subprocess.run(
                f"systemctl is-active {service_name}",
                shell=True, capture_output=True, text=True, timeout=2
            )
            health["status"] = result.stdout.strip()
        except:
            health["status"] = "unknown"

        try:
            inst_path = f"/var/python/openalgo-flask/{instance}"
            db_file = self._get_auth_db_file(instance)
            if db_file:
                health["database"] = True
        except:
            pass

        try:
            env_file = f"/var/python/openalgo-flask/{instance}/.env"
            if os.path.exists(env_file):
                with open(env_file, 'r') as f:
                    for line in f:
                        if line.startswith('DOMAIN=') and '=' in line:
                            health["domain"] = line.split('=', 1)[1].strip().strip("'\"")
                        elif line.startswith('FLASK_PORT') and '=' in line:
                            health["port"] = line.split('=')[1].strip().strip("'\"")
                        elif 'REDIRECT_URL' in line and '=' in line:
                            redirect_url = line.split('=', 1)[1].strip().strip("'\"")
                            # Extract broker from URL
                            import re
                            match = re.search(r'/([^/]+)/callback', redirect_url)
                            if match:
                                health["broker"] = match.group(1)
        except:
            pass

        try:
            authenticated, _, broker_db, name_db = self._read_auth_status(instance)
            health["session_valid"] = authenticated
            if broker_db:
                health["broker"] = broker_db
            if name_db:
                health["auth_name"] = name_db
        except:
            pass

        return health
    
    def handle_health(self):
        """Health check"""
        self.send_json({
            "status": "healthy",
            "service": "OpenAlgo Restart API",
            "timestamp": str(datetime.now())
        })
    
    def handle_restart_all(self):
        """Restart all instances"""
        Thread(target=self._restart_all).start()
        self.send_json({
            "status": "success",
            "message": "Restart triggered for all instances",
            "timestamp": str(datetime.now())
        })
    
    def handle_restart_instance(self, instance):
        """Restart specific instance"""
        service_name = self._service_name(instance)
        Thread(target=lambda: subprocess.run(
            f"sudo systemctl restart {service_name}",
            shell=True, capture_output=True, timeout=60
        )).start()
        
        self.send_json({
            "status": "success",
            "message": f"Restart triggered for {instance}",
            "instance": instance,
            "timestamp": str(datetime.now())
        })
    
    def handle_stop_instance(self, instance):
        """Stop specific instance"""
        service_name = self._service_name(instance)
        subprocess.run(
            f"sudo systemctl stop {service_name}",
            shell=True, capture_output=True, timeout=30
        )
        
        self.send_json({
            "status": "success",
            "message": f"Stopped {instance}",
            "instance": instance,
            "timestamp": str(datetime.now())
        })
    
    def handle_start_instance(self, instance):
        """Start specific instance"""
        service_name = self._service_name(instance)
        subprocess.run(
            f"sudo systemctl start {service_name}",
            shell=True, capture_output=True, timeout=30
        )

        self.send_json({
            "status": "success",
            "message": f"Started {instance}",
            "instance": instance,
            "timestamp": str(datetime.now())
        })

    def handle_reboot_server(self):
        """Reboot the server with fallback"""
        def _reboot():
            try:
                # Try primary reboot command
                result = subprocess.run(
                    "sudo systemctl reboot",
                    shell=True, capture_output=True, timeout=10
                )
                # If primary fails, use fallback
                if result.returncode != 0:
                    subprocess.run(
                        "sudo shutdown -r now",
                        shell=True, capture_output=True, timeout=10
                    )
            except Exception as e:
                # Final fallback
                try:
                    subprocess.run(
                        "sudo shutdown -r now",
                        shell=True, capture_output=True, timeout=10
                    )
                except:
                    pass

        # Run reboot in background thread so response can be sent before shutdown
        Thread(target=_reboot).start()

        self.send_json({
            "status": "success",
            "message": "Server reboot initiated. The system will restart shortly.",
            "timestamp": str(datetime.now())
        })

    def _restart_all(self):
        """Background restart all"""
        subprocess.run(['/usr/local/bin/openalgo-daily-restart.sh'],
                      capture_output=True, timeout=600)
    
    def serve_web_ui(self):
        """Serve HTML dashboard"""
        html = """<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenAlgo Manager</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:sans-serif;background:#667eea;min-height:100vh;display:flex;justify-content:center;align-items:center;padding:20px}
.container{background:white;border-radius:12px;box-shadow:0 20px 60px rgba(0,0,0,0.3);max-width:900px;width:100%}
.header{background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);color:white;padding:30px;text-align:center}
.header h1{font-size:28px;margin-bottom:10px}
.content{padding:30px}
.btn{padding:10px 20px;border:none;border-radius:6px;cursor:pointer;font-weight:600;margin:5px;white-space:nowrap}
.btn-primary{background:#667eea;color:white;width:100%;padding:12px;font-size:14px}
.btn-primary:hover{background:#5568d3}
.btn-restart{background:#667eea;color:white}
.btn-stop{background:#dc3545;color:white}
.btn-start{background:#28a745;color:white}
.btn-reboot{background:#ff6b6b;color:white}
.btn-reboot:hover{background:#ff5252}
.btn-small{padding:6px 12px;font-size:12px;margin:2px}
.btn:hover{opacity:0.9;transform:translateY(-2px)}
.instance{background:#f8f9fa;padding:15px;margin:10px 0;border-radius:8px;border-left:4px solid #667eea}
.instance-header{display:flex;justify-content:space-between;align-items:center}
.instance-name{font-weight:600;color:#333;font-size:16px}
.instance-details{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin-top:10px;padding-top:10px;border-top:1px solid #e0e0e0}
.detail-item{font-size:13px}
.detail-label{color:#666;font-weight:500}
.detail-value{color:#333;font-weight:600;margin-top:2px}
.status{font-size:12px;color:#666;margin-top:5px}
.active{color:#28a745}
.inactive{color:#dc3545}
.badge{padding:4px 8px;border-radius:4px;font-size:12px;font-weight:600;margin-left:10px}
.badge-active{background:#d4edda;color:#155724}
.badge-inactive{background:#f8d7da;color:#721c24}
.badge-info{background:#cfe2ff;color:#084298}
.badge-authenticated{background:#d4edda;color:#155724}
.badge-unauthenticated{background:#f8d7da;color:#721c24}
.alert{padding:15px;margin:20px 0;border-radius:8px;display:none}
.alert.show{display:block}
.alert-success{background:#d4edda;color:#155724;border:1px solid #c3e6cb}
.alert-error{background:#f8d7da;color:#721c24;border:1px solid #f5c6cb}
.alert-info{background:#d1ecf1;color:#0c5460;border:1px solid #bee5eb}
.loading{text-align:center;padding:40px;color:#666}
.spinner{border:3px solid #f3f3f3;border-top:3px solid #667eea;border-radius:50%;width:30px;height:30px;animation:spin 1s linear infinite;margin:0 auto 10px}
@keyframes spin{0%{transform:rotate(0deg)}100%{transform:rotate(360deg)}}
.summary{background:#f8f9fa;padding:20px;border-radius:8px;margin-bottom:20px;border-left:4px solid #667eea}
.actions{display:flex;gap:5px;flex-wrap:wrap;margin-top:10px;justify-content:flex-end}
.broker-status{margin-top:10px;padding:10px;background:#fff;border-radius:4px;border-left:3px solid #667eea;font-size:13px}
.logs-toggle{padding:8px 12px;background:#667eea;color:white;border:none;border-radius:4px;cursor:pointer;font-size:12px;margin-top:10px;width:100%}
.logs-toggle:hover{background:#5568d3}
.logs-section{display:none;margin-top:10px;padding:10px;background:#1e1e1e;border-radius:4px;border:1px solid #ccc}
.logs-section.show{display:block}
.logs-container{max-height:500px;overflow-y:auto;font-family:'Courier New',monospace;font-size:11px;color:#d4d4d4;line-height:1.4}
.log-line{padding:2px 5px;word-break:break-all}
.log-error{background:#c4444466;color:#ff6b6b}
.log-success{background:#22863a66;color:#85e89d}
</style>
</head>
<body>
<div class="container">
<div class="header">
<h1>🚀 OpenAlgo Manager</h1>
<p>Manage your OpenAlgo instances</p>
</div>
<div class="content">
<div id="alert" class="alert"></div>
<div class="summary">
<h3>Summary</h3>
<div id="summary"><p>Loading...</p></div>
</div>
<button class="btn btn-primary" onclick="restartAll()">🔄 Restart All Instances</button>
<button class="btn btn-primary" style="background:#28a745" onclick="loadInstances()">🔄 Refresh</button>
<button class="btn btn-primary btn-reboot" onclick="rebootServer()">⚡ Reboot Server</button>
<div id="loading" class="loading"><div class="spinner"></div><p>Loading instances...</p></div>
<div id="instances"></div>
</div>
</div>

<script>
let brokerStatusCache={};
let logsCache={};
async function loadInstances(){
try{
document.getElementById('loading').style.display='block';
const r1=await fetch('/api/instances');
const instances=await r1.json();
const r2=await fetch('/api/health');
const health=await r2.json();
document.getElementById('loading').style.display='none';
if(!instances||instances.length===0){
document.getElementById('instances').innerHTML='<p>No instances found</p>';
return;
}
const running=Object.values(health.instances||{}).filter(i=>i.status==='active').length;
document.getElementById('summary').innerHTML=`<p><strong>Total Instances:</strong> ${instances.length} | <strong>Running:</strong> <span class="active">${running}</span> | <strong>Stopped:</strong> <span class="inactive">${instances.length-running}</span></p>`;
const html=instances.map(inst=>{
const h=health.instances?.[inst]||{};
const active=h.status==='active';
const broker=h.broker||'Unknown';
const domain=h.domain||'Unknown';
const authName=h.auth_name||'Unknown';
const sessionValid=h.session_valid!==false;
const brokerAuthBadge=sessionValid?`<span class="badge badge-authenticated">✓ Authenticated</span>`:`<span class="badge badge-unauthenticated">✗ Not Authenticated</span>`;
return`<div class="instance"><div class="instance-header"><div><div class="instance-name">${inst}<span class="badge ${active?'badge-active':'badge-inactive'}">${active?'✓ Active':'✗ Inactive'}</span></div></div></div><div class="instance-details"><div class="detail-item"><div class="detail-label">Domain</div><div class="detail-value">${domain}</div></div><div class="detail-item"><div class="detail-label">Status</div><div class="detail-value ${active?'active':'inactive'}">${h.status||'unknown'}</div></div><div class="detail-item"><div class="detail-label">Flask Port</div><div class="detail-value">${h.port||'N/A'}</div></div><div class="detail-item"><div class="detail-label">Database</div><div class="detail-value">${h.database?'✓ Present':'✗ Missing'}</div></div></div><div class="broker-status"><strong>Broker:</strong> ${broker} | ${brokerAuthBadge}</div><button class="logs-toggle" onclick="toggleLogs('${inst}')">📋 View Logs</button><div id="logs-${inst}" class="logs-section"><div class="logs-container" id="logs-content-${inst}"><p style="color:#999">Loading logs...</p></div></div><div class="actions"><button class="btn btn-small btn-restart" onclick="restart('${inst}')">🔄 Restart</button>${active?`<button class="btn btn-small btn-stop" onclick="stop('${inst}')">⏹ Stop</button>`:`<button class="btn btn-small btn-start" onclick="start('${inst}')">▶ Start</button>`}</div></div>`;
return`<div class="instance"><div class="instance-header"><div><div class="instance-name">${inst}<span class="badge ${active?'badge-active':'badge-inactive'}">${active?'✓ Active':'✗ Inactive'}</span></div></div></div><div class="instance-details"><div class="detail-item"><div class="detail-label">Domain</div><div class="detail-value">${domain}</div></div><div class="detail-item"><div class="detail-label">Status</div><div class="detail-value ${active?'active':'inactive'}">${h.status||'unknown'}</div></div><div class="detail-item"><div class="detail-label">Flask Port</div><div class="detail-value">${h.port||'N/A'}</div></div><div class="detail-item"><div class="detail-label">Database</div><div class="detail-value">${h.database?'✓ Present':'✗ Missing'}</div></div></div><div class="broker-status"><strong>${authName}</strong> | <strong>Broker:</strong> ${broker} | ${brokerAuthBadge}</div><button class="logs-toggle" onclick="toggleLogs('${inst}')">📋 View Logs</button><div id="logs-${inst}" class="logs-section"><div class="logs-container" id="logs-content-${inst}"><p style="color:#999">Loading logs...</p></div></div><div class="actions"><button class="btn btn-small btn-restart" onclick="restart('${inst}')">🔄 Restart</button>${active?`<button class="btn btn-small btn-stop" onclick="stop('${inst}')">⏹ Stop</button>`:`<button class="btn btn-small btn-start" onclick="start('${inst}')">▶ Start</button>`}</div></div>`;
}).join('');
document.getElementById('instances').innerHTML=html;
}catch(e){
showAlert('Error: '+e.message,'error');
}
}
async function toggleLogs(inst){
const logsSection=document.getElementById(`logs-${inst}`);
logsSection.classList.toggle('show');
if(logsSection.classList.contains('show')&&!logsCache[inst]){
fetchLogs(inst);
}
}
async function fetchLogs(inst){
try{
const r=await fetch(`/api/logs/${inst}`);
const data=await r.json();
const logsContent=document.getElementById(`logs-content-${inst}`);
if(data.logs&&data.logs.length>0){
const html=data.logs.map(log=>{
const lowerLog=log.toLowerCase();
const hasAuthError=(lowerLog.includes('session expired')||lowerLog.includes('invalid session detected')||lowerLog.includes('no valid auth token'));
const hasSuccess=(lowerLog.includes('master contract download completed')||lowerLog.includes('successfully loaded'));
return`<div class="log-line ${hasAuthError?'log-error':''}${hasSuccess?'log-success':''}">${escapeHtml(log)}</div>`;
}).join('');
logsContent.innerHTML=html;
logsCache[inst]=true;
}else{
logsContent.innerHTML='<p style="color:#999">No logs available</p>';
}
}catch(e){
document.getElementById(`logs-content-${inst}`).innerHTML=`<p style="color:#ff6b6b">Error loading logs: ${e.message}</p>`;
}
}
function escapeHtml(text){
const map={'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'};
return text.replace(/[&<>"']/g,m=>map[m]);
}
async function restartAll(){
if(!confirm('Restart all instances?'))return;
showAlert('Restarting all...','info');
const r=await fetch('/api/restart-all',{method:'POST'});
const d=await r.json();
showAlert(d.message,'success');
setTimeout(loadInstances,2000);
}
async function restart(inst){
if(!confirm(`Restart ${inst}?`))return;
await fetch('/api/restart-instance',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({instance:inst})});
showAlert(`Restarting ${inst}`,'info');
setTimeout(loadInstances,1000);
}
async function stop(inst){
if(!confirm(`Stop ${inst}?`))return;
await fetch('/api/stop-instance',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({instance:inst})});
showAlert(`Stopping ${inst}`,'info');
setTimeout(loadInstances,1000);
}
async function start(inst){
if(!confirm(`Start ${inst}?`))return;
await fetch('/api/start-instance',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({instance:inst})});
showAlert(`Starting ${inst}`,'info');
setTimeout(loadInstances,1000);
}
async function rebootServer(){
if(!confirm('⚠️ Are you sure you want to reboot the server? This will disconnect all instances!'))return;
if(!confirm('⚠️ FINAL CONFIRMATION: The server will restart now. Continue?'))return;
showAlert('Rebooting server... Connection will be lost shortly.','info');
try{
const r=await fetch('/api/reboot-server',{method:'POST'});
const d=await r.json();
showAlert(d.message,'success');
}catch(e){
showAlert('Reboot initiated (API connection lost as expected)','success');
}
}
function showAlert(msg,type){
const a=document.getElementById('alert');
a.textContent=msg;
a.className=`alert alert-${type} show`;
if(type!=='error')setTimeout(()=>a.classList.remove('show'),4000);
}
window.addEventListener('load',loadInstances);
setInterval(loadInstances,30000);
</script>
</body>
</html>"""
        
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate')
        self.send_header('Pragma', 'no-cache')
        self.send_header('Expires', '0')
        self.send_header('Content-Length', len(html))
        self.end_headers()
        self.wfile.write(html.encode('utf-8'))
    
    def send_json(self, data, status=200):
        """Send JSON response"""
        json_str = json.dumps(data)
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate')
        self.send_header('Pragma', 'no-cache')
        self.send_header('Expires', '0')
        self.send_header('Content-Length', len(json_str))
        self.end_headers()
        self.wfile.write(json_str.encode('utf-8'))
    
    def log_message(self, format, *args):
        """Suppress logging"""
        pass

if __name__ == '__main__':
    PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8888

    class ReusableTCPServer(socketserver.TCPServer):
        allow_reuse_address = True

    server = ReusableTCPServer(("0.0.0.0", PORT), RestartHandler)
    
    print(f"OpenAlgo API running on 0.0.0.0:{PORT}", flush=True)
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Server stopped", flush=True)
    except Exception as e:
        print(f"Error: {e}", flush=True)
        sys.exit(1)
