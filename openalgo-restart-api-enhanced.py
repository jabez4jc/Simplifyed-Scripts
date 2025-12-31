#!/usr/bin/env python3
"""
OpenAlgo Enhanced REST API with Web UI
Supports restarting all instances or specific instances
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

class RestartHandler(http.server.SimpleHTTPRequestHandler):
    
    def do_GET(self):
        """Handle GET requests"""
        parsed_path = urlparse(self.path)
        path = parsed_path.path
        
        if path == '/':
            # Serve web UI
            self.serve_web_ui()
        elif path == '/api/instances':
            # Get list of instances
            self.send_json_response(self.get_instances())
        elif path == '/api/status':
            # Get status of all instances
            self.send_json_response(self.get_instance_status())
        elif path == '/health':
            # Health check
            self.send_json_response({
                "status": "healthy",
                "service": "OpenAlgo Restart API",
                "timestamp": str(datetime.now())
            })
        else:
            self.send_error_response(404, "Endpoint not found")
    
    def do_POST(self):
        """Handle POST requests"""
        parsed_path = urlparse(self.path)
        path = parsed_path.path
        
        # Read request body
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode('utf-8')
        
        try:
            data = json.loads(body) if body else {}
        except json.JSONDecodeError:
            self.send_error_response(400, "Invalid JSON")
            return
        
        if path == '/api/restart-all':
            # Restart all instances
            self.trigger_restart_all()
            self.send_json_response({
                "status": "success",
                "message": "Restart triggered for all OpenAlgo instances",
                "timestamp": str(datetime.now())
            })
        elif path == '/api/restart-instance':
            # Restart specific instance
            instance_name = data.get('instance')
            if not instance_name:
                self.send_error_response(400, "Missing 'instance' parameter")
                return
            
            if self.trigger_restart_instance(instance_name):
                self.send_json_response({
                    "status": "success",
                    "message": f"Restart triggered for {instance_name}",
                    "instance": instance_name,
                    "timestamp": str(datetime.now())
                })
            else:
                self.send_error_response(400, f"Instance {instance_name} not found or failed to restart")
        elif path == '/api/stop-instance':
            # Stop specific instance
            instance_name = data.get('instance')
            if not instance_name:
                self.send_error_response(400, "Missing 'instance' parameter")
                return
            
            if self.stop_instance(instance_name):
                self.send_json_response({
                    "status": "success",
                    "message": f"Stopped {instance_name}",
                    "instance": instance_name,
                    "timestamp": str(datetime.now())
                })
            else:
                self.send_error_response(400, f"Failed to stop {instance_name}")
        elif path == '/api/start-instance':
            # Start specific instance
            instance_name = data.get('instance')
            if not instance_name:
                self.send_error_response(400, "Missing 'instance' parameter")
                return
            
            if self.start_instance(instance_name):
                self.send_json_response({
                    "status": "success",
                    "message": f"Started {instance_name}",
                    "instance": instance_name,
                    "timestamp": str(datetime.now())
                })
            else:
                self.send_error_response(400, f"Failed to start {instance_name}")
        else:
            self.send_error_response(404, "Endpoint not found")
    
    def serve_web_ui(self):
        """Serve the web UI"""
        html = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>OpenAlgo Instance Manager</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            justify-content: center;
            align-items: center;
            padding: 20px;
        }
        
        .container {
            background: white;
            border-radius: 12px;
            box-shadow: 0 20px 60px rgba(0, 0, 0, 0.3);
            max-width: 800px;
            width: 100%;
            overflow: hidden;
        }
        
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            text-align: center;
        }
        
        .header h1 {
            font-size: 28px;
            margin-bottom: 5px;
        }
        
        .header p {
            opacity: 0.9;
            font-size: 14px;
        }
        
        .content {
            padding: 30px;
        }
        
        .status-card {
            background: #f8f9fa;
            padding: 20px;
            border-radius: 8px;
            margin-bottom: 20px;
            border-left: 4px solid #667eea;
        }
        
        .status-card h3 {
            color: #333;
            margin-bottom: 10px;
            font-size: 16px;
        }
        
        .instances-grid {
            display: grid;
            gap: 15px;
            margin-bottom: 20px;
        }
        
        .instance-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 15px;
            background: #f8f9fa;
            border-radius: 8px;
            border: 1px solid #e9ecef;
            transition: all 0.3s ease;
        }
        
        .instance-item:hover {
            border-color: #667eea;
            box-shadow: 0 4px 12px rgba(102, 126, 234, 0.1);
        }
        
        .instance-info {
            flex: 1;
        }
        
        .instance-name {
            font-weight: 600;
            color: #333;
            margin-bottom: 5px;
        }
        
        .instance-status {
            font-size: 13px;
            color: #666;
        }
        
        .status-badge {
            display: inline-block;
            padding: 4px 8px;
            border-radius: 4px;
            font-size: 12px;
            font-weight: 600;
            margin-left: 10px;
        }
        
        .status-active {
            background: #d4edda;
            color: #155724;
        }
        
        .status-inactive {
            background: #f8d7da;
            color: #721c24;
        }
        
        .instance-actions {
            display: flex;
            gap: 8px;
        }
        
        button {
            padding: 8px 16px;
            border: none;
            border-radius: 6px;
            font-size: 13px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.3s ease;
            white-space: nowrap;
        }
        
        .btn-restart {
            background: #667eea;
            color: white;
        }
        
        .btn-restart:hover {
            background: #5568d3;
            transform: translateY(-2px);
        }
        
        .btn-stop {
            background: #dc3545;
            color: white;
        }
        
        .btn-stop:hover {
            background: #c82333;
        }
        
        .btn-start {
            background: #28a745;
            color: white;
        }
        
        .btn-start:hover {
            background: #218838;
        }
        
        .btn-primary {
            background: #667eea;
            color: white;
            padding: 12px 24px;
            font-size: 14px;
            width: 100%;
            margin-top: 10px;
        }
        
        .btn-primary:hover {
            background: #5568d3;
        }
        
        .btn-primary:disabled {
            background: #ccc;
            cursor: not-allowed;
            opacity: 0.6;
        }
        
        .button-group {
            display: flex;
            gap: 10px;
            margin-top: 20px;
        }
        
        .button-group button {
            flex: 1;
        }
        
        .alert {
            padding: 15px;
            border-radius: 8px;
            margin-bottom: 20px;
            display: none;
        }
        
        .alert.show {
            display: block;
        }
        
        .alert-success {
            background: #d4edda;
            color: #155724;
            border: 1px solid #c3e6cb;
        }
        
        .alert-error {
            background: #f8d7da;
            color: #721c24;
            border: 1px solid #f5c6cb;
        }
        
        .alert-info {
            background: #d1ecf1;
            color: #0c5460;
            border: 1px solid #bee5eb;
        }
        
        .loading {
            display: none;
            text-align: center;
            padding: 20px;
            color: #666;
        }
        
        .spinner {
            border: 3px solid #f3f3f3;
            border-top: 3px solid #667eea;
            border-radius: 50%;
            width: 30px;
            height: 30px;
            animation: spin 1s linear infinite;
            margin: 0 auto 10px;
        }
        
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
        
        .empty-state {
            text-align: center;
            padding: 40px 20px;
            color: #666;
        }
        
        .empty-state svg {
            width: 60px;
            height: 60px;
            margin-bottom: 15px;
            opacity: 0.5;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🚀 OpenAlgo Instance Manager</h1>
            <p>Manage and monitor your OpenAlgo instances</p>
        </div>
        
        <div class="content">
            <div id="alert" class="alert"></div>
            
            <div class="status-card">
                <h3>Instance Summary</h3>
                <div id="summary" style="font-size: 14px; color: #666;">
                    <p>Loading instances...</p>
                </div>
            </div>
            
            <div class="button-group">
                <button class="btn-primary" onclick="restartAll()" style="background: #667eea;">
                    🔄 Restart All Instances
                </button>
                <button class="btn-primary" onclick="loadInstances()" style="background: #28a745;">
                    🔄 Refresh
                </button>
            </div>
            
            <div style="margin-top: 30px;">
                <h3 style="color: #333; margin-bottom: 15px;">Individual Instance Control</h3>
                <div id="loading" class="loading">
                    <div class="spinner"></div>
                    <p>Loading instances...</p>
                </div>
                <div id="instances" class="instances-grid">
                </div>
                <div id="empty" class="empty-state" style="display: none;">
                    <p>No instances found</p>
                </div>
            </div>
        </div>
    </div>
    
    <script>
        async function loadInstances() {
            try {
                document.getElementById('loading').style.display = 'block';
                document.getElementById('instances').innerHTML = '';
                
                // Get instances list
                const response = await fetch('/api/instances');
                const instances = await response.json();
                
                // Get status for each instance
                const statusResponse = await fetch('/api/status');
                const statusData = await statusResponse.json();
                
                document.getElementById('loading').style.display = 'none';
                
                if (!instances || instances.length === 0) {
                    document.getElementById('empty').style.display = 'block';
                    document.getElementById('summary').innerHTML = 'No instances found';
                    return;
                }
                
                document.getElementById('empty').style.display = 'none';
                
                // Update summary
                const activeCount = Object.values(statusData.instances || {}).filter(s => s === 'active').length;
                document.getElementById('summary').innerHTML = 
                    `<p><strong>Total Instances:</strong> ${instances.length}</p>
                     <p><strong>Running:</strong> ${activeCount} / ${instances.length}</p>`;
                
                // Render instances
                const instancesHtml = instances.map(inst => {
                    const status = statusData.instances?.[inst] || 'unknown';
                    const isActive = status === 'active';
                    
                    return `
                    <div class="instance-item">
                        <div class="instance-info">
                            <div class="instance-name">
                                ${inst}
                                <span class="status-badge ${isActive ? 'status-active' : 'status-inactive'}">
                                    ${isActive ? '● Active' : '● Inactive'}
                                </span>
                            </div>
                            <div class="instance-status">Status: ${status}</div>
                        </div>
                        <div class="instance-actions">
                            <button class="btn-restart" onclick="restartInstance('${inst}')">Restart</button>
                            ${isActive ? 
                                `<button class="btn-stop" onclick="stopInstance('${inst}')">Stop</button>` :
                                `<button class="btn-start" onclick="startInstance('${inst}')">Start</button>`
                            }
                        </div>
                    </div>
                    `;
                }).join('');
                
                document.getElementById('instances').innerHTML = instancesHtml;
            } catch (error) {
                showAlert('Error loading instances: ' + error.message, 'error');
                document.getElementById('loading').style.display = 'none';
            }
        }
        
        async function restartAll() {
            if (!confirm('Restart all instances? This will cause a brief outage.')) return;
            
            try {
                showAlert('Restarting all instances...', 'info');
                const response = await fetch('/api/restart-all', { method: 'POST' });
                const data = await response.json();
                
                if (response.ok) {
                    showAlert('✓ All instances are restarting', 'success');
                    setTimeout(loadInstances, 2000);
                } else {
                    showAlert('Error: ' + data.message, 'error');
                }
            } catch (error) {
                showAlert('Error restarting instances: ' + error.message, 'error');
            }
        }
        
        async function restartInstance(instance) {
            if (!confirm(`Restart ${instance}?`)) return;
            
            try {
                showAlert(`Restarting ${instance}...`, 'info');
                const response = await fetch('/api/restart-instance', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ instance })
                });
                const data = await response.json();
                
                if (response.ok) {
                    showAlert(`✓ ${instance} is restarting`, 'success');
                    setTimeout(loadInstances, 1000);
                } else {
                    showAlert('Error: ' + data.message, 'error');
                }
            } catch (error) {
                showAlert('Error: ' + error.message, 'error');
            }
        }
        
        async function stopInstance(instance) {
            if (!confirm(`Stop ${instance}?`)) return;
            
            try {
                showAlert(`Stopping ${instance}...`, 'info');
                const response = await fetch('/api/stop-instance', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ instance })
                });
                const data = await response.json();
                
                if (response.ok) {
                    showAlert(`✓ ${instance} stopped`, 'success');
                    setTimeout(loadInstances, 1000);
                } else {
                    showAlert('Error: ' + data.message, 'error');
                }
            } catch (error) {
                showAlert('Error: ' + error.message, 'error');
            }
        }
        
        async function startInstance(instance) {
            if (!confirm(`Start ${instance}?`)) return;
            
            try {
                showAlert(`Starting ${instance}...`, 'info');
                const response = await fetch('/api/start-instance', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ instance })
                });
                const data = await response.json();
                
                if (response.ok) {
                    showAlert(`✓ ${instance} started`, 'success');
                    setTimeout(loadInstances, 1000);
                } else {
                    showAlert('Error: ' + data.message, 'error');
                }
            } catch (error) {
                showAlert('Error: ' + error.message, 'error');
            }
        }
        
        function showAlert(message, type) {
            const alert = document.getElementById('alert');
            alert.textContent = message;
            alert.className = `alert alert-${type} show`;
            
            if (type !== 'error') {
                setTimeout(() => alert.classList.remove('show'), 4000);
            }
        }
        
        // Load instances on page load
        window.addEventListener('load', loadInstances);
        
        // Auto-refresh every 30 seconds
        setInterval(loadInstances, 30000);
    </script>
</body>
</html>
"""
        
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', len(html))
        self.end_headers()
        self.wfile.write(html.encode('utf-8'))
    
    def get_instances(self):
        """Get list of all instances"""
        try:
            result = subprocess.run(
                ['bash', '-c', 'ls -1 /var/python/openalgo-flask 2>/dev/null | grep "^openalgo"'],
                capture_output=True, text=True, timeout=5
            )
            instances = [inst.strip() for inst in result.stdout.strip().split('\n') if inst.strip()]
            return sorted(instances)
        except Exception as e:
            return {"error": str(e)}
    
    def get_instance_status(self):
        """Get status of all instances"""
        try:
            instances = self.get_instances()
            status_info = {
                "total_instances": len(instances) if isinstance(instances, list) else 0,
                "instances": {},
                "timestamp": str(datetime.now())
            }
            
            if isinstance(instances, list):
                for inst in instances:
                    try:
                        result = subprocess.run(
                            ['systemctl', 'is-active', inst],
                            capture_output=True, text=True, timeout=2
                        )
                        status_info["instances"][inst] = result.stdout.strip()
                    except:
                        status_info["instances"][inst] = "unknown"
            
            return status_info
        except Exception as e:
            return {"error": str(e), "timestamp": str(datetime.now())}
    
    def trigger_restart_all(self):
        """Trigger restart of all instances"""
        Thread(target=self._restart_all_background).start()
    
    def _restart_all_background(self):
        """Run restart in background"""
        try:
            subprocess.run(['/usr/local/bin/openalgo-daily-restart.sh'], 
                          check=True, capture_output=True, timeout=600)
        except Exception as e:
            print(f"Error restarting all instances: {e}", file=sys.stderr)
    
    def trigger_restart_instance(self, instance):
        """Trigger restart of specific instance"""
        try:
            # Verify instance exists
            instances = self.get_instances()
            if instance not in instances:
                return False
            
            # Run restart in background
            Thread(target=self._restart_instance_background, args=(instance,)).start()
            return True
        except Exception:
            return False
    
    def _restart_instance_background(self, instance):
        """Run instance restart in background"""
        try:
            subprocess.run(['sudo', 'systemctl', 'restart', instance], 
                          check=True, capture_output=True, timeout=60)
        except Exception as e:
            print(f"Error restarting {instance}: {e}", file=sys.stderr)
    
    def stop_instance(self, instance):
        """Stop specific instance"""
        try:
            instances = self.get_instances()
            if instance not in instances:
                return False
            
            subprocess.run(['sudo', 'systemctl', 'stop', instance], 
                          check=True, capture_output=True, timeout=30)
            return True
        except Exception:
            return False
    
    def start_instance(self, instance):
        """Start specific instance"""
        try:
            instances = self.get_instances()
            if instance not in instances:
                return False
            
            subprocess.run(['sudo', 'systemctl', 'start', instance], 
                          check=True, capture_output=True, timeout=30)
            return True
        except Exception:
            return False
    
    def send_json_response(self, data, status_code=200):
        """Send JSON response"""
        json_response = json.dumps(data).encode('utf-8')
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(json_response))
        self.end_headers()
        self.wfile.write(json_response)
    
    def send_error_response(self, status_code, message):
        """Send error response"""
        self.send_json_response({
            "error": message,
            "status_code": status_code,
            "timestamp": str(datetime.now())
        }, status_code)
    
    def log_message(self, format, *args):
        """Suppress default logging"""
        pass

def run_api(port):
    """Run the API server"""
    handler = RestartHandler
    try:
        with socketserver.TCPServer(("", port), handler) as httpd:
            print(f"OpenAlgo REST API running on http://0.0.0.0:{port}")
            print(f"Web UI available at http://localhost:{port}")
            sys.stdout.flush()
            httpd.serve_forever()
    except Exception as e:
        print(f"Error starting server: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8888
    run_api(port)
