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
from threading import Thread
from urllib.parse import urlparse, parse_qs
from datetime import datetime

PORT = 8888

class RestartHandler(http.server.BaseHTTPRequestHandler):
    
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
        else:
            self.send_json({"error": "Not found"}, 404)
    
    def handle_instances(self):
        """Get list of instances"""
        try:
            result = subprocess.run(
                "ls -1 /var/python/openalgo-flask 2>/dev/null | grep '^openalgo'",
                shell=True, capture_output=True, text=True, timeout=5
            )
            instances = [i.strip() for i in result.stdout.strip().split('\n') if i.strip()]
            self.send_json(sorted(instances))
        except Exception as e:
            self.send_json({"error": str(e)}, 500)
    
    def handle_status(self):
        """Get status of all instances"""
        try:
            result = subprocess.run(
                "ls -1 /var/python/openalgo-flask 2>/dev/null | grep '^openalgo'",
                shell=True, capture_output=True, text=True, timeout=5
            )
            instances = [i.strip() for i in result.stdout.strip().split('\n') if i.strip()]
            
            status = {"total": len(instances), "instances": {}, "timestamp": str(datetime.now())}
            
            for inst in instances:
                try:
                    result = subprocess.run(
                        f"systemctl is-active {inst}",
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
            result = subprocess.run(
                "ls -1 /var/python/openalgo-flask 2>/dev/null | grep '^openalgo'",
                shell=True, capture_output=True, text=True, timeout=5
            )
            instances = [i.strip() for i in result.stdout.strip().split('\n') if i.strip()]
            
            health = {"total": len(instances), "instances": {}, "timestamp": str(datetime.now())}
            
            for inst in instances:
                health["instances"][inst] = self._get_instance_health(inst)
            
            self.send_json(health)
        except Exception as e:
            self.send_json({"error": str(e)}, 500)
    
    def _get_instance_health(self, instance):
        """Get detailed health info for a single instance"""
        health = {"name": instance, "status": "unknown", "port": None, "database": False, "logs": []}
        
        try:
            result = subprocess.run(
                f"systemctl is-active {instance}",
                shell=True, capture_output=True, text=True, timeout=2
            )
            health["status"] = result.stdout.strip()
        except:
            health["status"] = "unknown"
        
        try:
            inst_path = f"/var/python/openalgo-flask/{instance}"
            if os.path.exists(f"{inst_path}/db/openalgo.db"):
                health["database"] = True
        except:
            pass
        
        try:
            env_file = f"/var/python/openalgo-flask/{instance}/.env"
            if os.path.exists(env_file):
                with open(env_file, 'r') as f:
                    for line in f:
                        if line.startswith('FLASK_PORT='):
                            health["port"] = line.split('=')[1].strip()
                            break
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
        Thread(target=lambda: subprocess.run(
            f"sudo systemctl restart {instance}",
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
        subprocess.run(
            f"sudo systemctl stop {instance}",
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
        subprocess.run(
            f"sudo systemctl start {instance}",
            shell=True, capture_output=True, timeout=30
        )
        
        self.send_json({
            "status": "success",
            "message": f"Started {instance}",
            "instance": instance,
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
<div id="loading" class="loading"><div class="spinner"></div><p>Loading instances...</p></div>
<div id="instances"></div>
</div>
</div>

<script>
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
return`<div class="instance"><div class="instance-header"><div><div class="instance-name">${inst}<span class="badge ${active?'badge-active':'badge-inactive'}">${active?'✓ Active':'✗ Inactive'}</span></div></div></div><div class="instance-details"><div class="detail-item"><div class="detail-label">Status</div><div class="detail-value ${active?'active':'inactive'}">${h.status||'unknown'}</div></div><div class="detail-item"><div class="detail-label">Flask Port</div><div class="detail-value">${h.port||'N/A'}</div></div><div class="detail-item"><div class="detail-label">Database</div><div class="detail-value">${h.database?'✓ Present':'✗ Missing'}</div></div></div><div class="actions"><button class="btn btn-small btn-restart" onclick="restart('${inst}')">🔄 Restart</button>${active?`<button class="btn btn-small btn-stop" onclick="stop('${inst}')">⏹ Stop</button>`:`<button class="btn btn-small btn-start" onclick="start('${inst}')">▶ Start</button>`}</div></div>`;
}).join('');
document.getElementById('instances').innerHTML=html;
}catch(e){
showAlert('Error: '+e.message,'error');
}
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
        self.send_header('Content-Length', len(html))
        self.end_headers()
        self.wfile.write(html.encode('utf-8'))
    
    def send_json(self, data, status=200):
        """Send JSON response"""
        json_str = json.dumps(data)
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(json_str))
        self.end_headers()
        self.wfile.write(json_str.encode('utf-8'))
    
    def log_message(self, format, *args):
        """Suppress logging"""
        pass

if __name__ == '__main__':
    PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8888
    
    server = socketserver.TCPServer(("0.0.0.0", PORT), RestartHandler)
    server.allow_reuse_address = True
    
    print(f"OpenAlgo API running on 0.0.0.0:{PORT}", flush=True)
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Server stopped", flush=True)
    except Exception as e:
        print(f"Error: {e}", flush=True)
        sys.exit(1)
