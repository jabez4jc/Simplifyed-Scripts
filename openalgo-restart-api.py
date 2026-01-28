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
import time
import uuid
import re
import shutil
from threading import Thread, Lock
from urllib.parse import urlparse, parse_qs
from datetime import datetime, timedelta, timezone

PORT = 8888

class RestartHandler(http.server.BaseHTTPRequestHandler):
    JOBS = {}
    JOBS_LOCK = Lock()
    JOB_LIMIT = 50

    def _now_iso(self):
        return datetime.now().isoformat(sep=' ', timespec='seconds')

    def _strip_ansi(self, text):
        if not text:
            return text
        ansi_re = re.compile(r"\x1B\[[0-?]*[ -/]*[@-~]")
        return ansi_re.sub("", text)

    def _find_script(self, script_name):
        env_dirs = [
            os.environ.get("OPENALGO_SCRIPTS_DIR"),
            os.environ.get("OA_SCRIPTS_DIR"),
            os.environ.get("SCRIPTS_DIR"),
        ]
        candidates = []
        # Default server path for scripts
        default_root_dir = "/root/Simplifyed-Scripts"
        candidates.append(os.path.join(default_root_dir, script_name))
        for env_dir in env_dirs:
            if env_dir:
                candidates.append(os.path.join(env_dir, script_name))

        base_dir = os.path.dirname(os.path.abspath(__file__))
        candidates.extend([
            os.path.join(base_dir, script_name),
            os.path.join(os.getcwd(), script_name),
            f"/usr/local/bin/{script_name}",
            f"/usr/bin/{script_name}",
            f"/usr/local/sbin/{script_name}",
            f"/usr/sbin/{script_name}",
        ])
        for path in candidates:
            if os.path.exists(path):
                return path
        path_hit = shutil.which(script_name)
        if path_hit:
            return path_hit
        return None

    def _prune_jobs_locked(self):
        if len(self.JOBS) <= self.JOB_LIMIT:
            return
        ordered = sorted(self.JOBS.items(), key=lambda item: item[1].get("created_ts", 0))
        for job_id, _ in ordered[:-self.JOB_LIMIT]:
            self.JOBS.pop(job_id, None)

    def _create_job(self, action, params):
        job_id = uuid.uuid4().hex[:12]
        job = {
            "id": job_id,
            "action": action,
            "params": params,
            "status": "queued",
            "created_at": self._now_iso(),
            "created_ts": time.time(),
            "started_at": None,
            "finished_at": None,
            "exit_code": None,
            "output": "",
            "error": None,
        }
        with self.JOBS_LOCK:
            self.JOBS[job_id] = job
            self._prune_jobs_locked()
        return job_id

    def _update_job(self, job_id, **updates):
        with self.JOBS_LOCK:
            job = self.JOBS.get(job_id)
            if not job:
                return None
            job.update(updates)
            return job

    def _get_job(self, job_id):
        with self.JOBS_LOCK:
            job = self.JOBS.get(job_id)
            return dict(job) if job else None

    def _run_script_job(self, job_id, command, timeout=900):
        self._update_job(job_id, status="running", started_at=self._now_iso())
        try:
            result = subprocess.run(
                command,
                capture_output=True,
                text=True,
                timeout=timeout
            )
            output = (result.stdout or "") + ("\n" + result.stderr if result.stderr else "")
            output = self._strip_ansi(output)
            if len(output) > 200000:
                output = output[:200000] + "\n...\n(Output truncated)"
            self._update_job(
                job_id,
                status="success" if result.returncode == 0 else "error",
                exit_code=result.returncode,
                output=output.strip(),
                finished_at=self._now_iso()
            )
        except subprocess.TimeoutExpired as e:
            output = (e.stdout or "") + ("\n" + e.stderr if e.stderr else "")
            output = self._strip_ansi(output)
            self._update_job(
                job_id,
                status="timeout",
                exit_code=None,
                output=output.strip(),
                error="Command timed out",
                finished_at=self._now_iso()
            )
        except Exception as e:
            self._update_job(
                job_id,
                status="error",
                exit_code=None,
                error=str(e),
                finished_at=self._now_iso()
            )
    def _db_has_table(self, db_file, table_name):
        try:
            conn = sqlite3.connect(db_file)
            cur = conn.cursor()
            cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name=?", (table_name,))
            found = cur.fetchone() is not None
            conn.close()
            return found
        except Exception:
            return False

    def _db_has_auth_table(self, db_file):
        return self._db_has_table(db_file, "auth")

    def _get_db_file_with_table(self, instance, table_name):
        inst_path = f"/var/python/openalgo-flask/{instance}"
        instance_num = instance.replace('openalgo', '')
        db_dir = f"{inst_path}/db"
        candidates = []

        if instance_num.isdigit():
            candidates.append(f"{db_dir}/openalgo{instance_num}.db")
        candidates.append(f"{db_dir}/openalgo.db")

        for path in candidates:
            if os.path.exists(path) and self._db_has_table(path, table_name):
                return path

        if os.path.isdir(db_dir):
            for entry in os.scandir(db_dir):
                if entry.is_file() and entry.name.endswith(".db"):
                    if self._db_has_table(entry.path, table_name):
                        return entry.path
        return None

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

    def _parse_db_datetime(self, value):
        if value is None:
            return None
        if isinstance(value, datetime):
            return value
        value = str(value).strip()
        for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S"):
            try:
                return datetime.strptime(value, fmt)
            except Exception:
                continue
        try:
            return datetime.fromisoformat(value)
        except Exception:
            return None

    def _ist_now(self):
        ist = datetime.now(timezone.utc).astimezone(timezone(timedelta(hours=5, minutes=30)))
        return ist.replace(tzinfo=None)

    def _ist_window_start(self, now_ist):
        window_start = now_ist.replace(hour=3, minute=0, second=0, microsecond=0)
        if now_ist < window_start:
            window_start -= timedelta(days=1)
        return window_start

    def _read_cpu_times(self):
        try:
            with open("/proc/stat", "r") as f:
                line = f.readline()
            parts = line.split()
            if len(parts) < 5 or parts[0] != "cpu":
                return None, None
            values = [int(p) for p in parts[1:]]
            total = sum(values)
            idle = values[3] + (values[4] if len(values) > 4 else 0)
            return total, idle
        except Exception:
            return None, None

    def _get_system_stats(self):
        stats = {
            "cpu_percent": None,
            "load1": None,
            "load5": None,
            "load15": None,
            "mem_total": None,
            "mem_used": None,
            "mem_available": None,
            "mem_percent": None,
            "swap_total": None,
            "swap_used": None,
            "swap_percent": None,
            "disk_total": None,
            "disk_used": None,
            "disk_free": None,
            "disk_percent": None,
        }

        total1, idle1 = self._read_cpu_times()
        time.sleep(0.1)
        total2, idle2 = self._read_cpu_times()
        if total1 is not None and total2 is not None:
            total_delta = total2 - total1
            idle_delta = idle2 - idle1
            if total_delta > 0:
                stats["cpu_percent"] = round(100.0 * (1.0 - (idle_delta / total_delta)), 1)

        try:
            load1, load5, load15 = os.getloadavg()
            stats["load1"] = round(load1, 2)
            stats["load5"] = round(load5, 2)
            stats["load15"] = round(load15, 2)
        except Exception:
            pass

        try:
            meminfo = {}
            with open("/proc/meminfo", "r") as f:
                for line in f:
                    parts = line.split(":")
                    if len(parts) != 2:
                        continue
                    key = parts[0].strip()
                    val_parts = parts[1].strip().split()
                    if not val_parts:
                        continue
                    meminfo[key] = int(val_parts[0]) * 1024
            mem_total = meminfo.get("MemTotal")
            mem_available = meminfo.get("MemAvailable")
            if mem_total is not None and mem_available is not None:
                mem_used = mem_total - mem_available
                stats["mem_total"] = mem_total
                stats["mem_available"] = mem_available
                stats["mem_used"] = mem_used
                stats["mem_percent"] = round(100.0 * mem_used / mem_total, 1)

            swap_total = meminfo.get("SwapTotal")
            swap_free = meminfo.get("SwapFree")
            if swap_total is not None and swap_free is not None and swap_total > 0:
                swap_used = swap_total - swap_free
                stats["swap_total"] = swap_total
                stats["swap_used"] = swap_used
                stats["swap_percent"] = round(100.0 * swap_used / swap_total, 1)
            elif swap_total is not None:
                stats["swap_total"] = swap_total
                stats["swap_used"] = 0
                stats["swap_percent"] = 0.0
        except Exception:
            pass

        try:
            stat = os.statvfs("/")
            total = stat.f_frsize * stat.f_blocks
            free = stat.f_frsize * stat.f_bavail
            used = total - free
            if total > 0:
                stats["disk_total"] = total
                stats["disk_free"] = free
                stats["disk_used"] = used
                stats["disk_percent"] = round(100.0 * used / total, 1)
        except Exception:
            pass

        return stats

    def _get_master_contract_status(self, instance):
        db_file = self._get_db_file_with_table(instance, "master_contract_status")
        if not db_file:
            return {
                "is_ready": False,
                "status": "Master Contract Data Not Ready",
                "last_updated": None,
                "total_symbols": None,
                "message": None,
                "broker": None,
            }

        try:
            conn = sqlite3.connect(db_file)
            cur = conn.cursor()
            cur.execute(
                "SELECT broker, message, last_updated, total_symbols, is_ready "
                "FROM master_contract_status ORDER BY last_updated DESC LIMIT 1"
            )
            latest = cur.fetchone()

            cur.execute(
                "SELECT broker, message, last_updated, total_symbols, is_ready "
                "FROM master_contract_status WHERE is_ready=1 "
                "ORDER BY last_updated DESC LIMIT 20"
            )
            ready_rows = cur.fetchall()
            conn.close()

            now_ist = self._ist_now()
            window_start = self._ist_window_start(now_ist)
            window_end = window_start + timedelta(days=1)

            ready_row = None
            for row in ready_rows:
                row_dt = self._parse_db_datetime(row[2])
                if row_dt and window_start <= row_dt < window_end:
                    ready_row = row
                    break

            is_ready = ready_row is not None
            status = "Master Contract Data Ready" if is_ready else "Master Contract Data Not Ready"

            if latest:
                broker, message, last_updated, total_symbols, _ = latest
            else:
                broker = message = last_updated = total_symbols = None

            return {
                "is_ready": is_ready,
                "status": status,
                "last_updated": last_updated,
                "total_symbols": total_symbols,
                "message": message,
                "broker": broker,
            }
        except Exception:
            return {
                "is_ready": False,
                "status": "Master Contract Data Not Ready",
                "last_updated": None,
                "total_symbols": None,
                "message": None,
                "broker": None,
            }

    def _invalidate_session(self, instance):
        """Invalidate session by clearing auth tokens and marking revoked; delete today's master contract status."""
        result = {"instance": instance, "auth_updated": False, "auth_error": None, "master_deleted": 0, "master_error": None}

        auth_db = self._get_db_file_with_table(instance, "auth")
        if auth_db:
            try:
                conn = sqlite3.connect(auth_db)
                cur = conn.cursor()
                cur.execute("UPDATE auth SET auth=NULL, feed_token=NULL, is_revoked=1")
                conn.commit()
                conn.close()
                result["auth_updated"] = True
            except Exception as e:
                result["auth_error"] = str(e)
        else:
            result["auth_error"] = "Auth database not found"

        master_db = self._get_db_file_with_table(instance, "master_contract_status")
        if master_db:
            try:
                now_ist = self._ist_now()
                window_start = self._ist_window_start(now_ist)
                window_end = window_start + timedelta(days=1)
                start_str = window_start.strftime("%Y-%m-%d %H:%M:%S")
                end_str = window_end.strftime("%Y-%m-%d %H:%M:%S")

                conn = sqlite3.connect(master_db)
                cur = conn.cursor()
                cur.execute(
                    "DELETE FROM master_contract_status "
                    "WHERE datetime(last_updated) >= datetime(?) AND datetime(last_updated) < datetime(?)",
                    (start_str, end_str),
                )
                conn.commit()
                result["master_deleted"] = cur.rowcount if cur.rowcount is not None else 0
                conn.close()
            except Exception as e:
                result["master_error"] = str(e)
        else:
            result["master_error"] = "Master contract table not found"

        return result

    def _read_auth_status(self, instance):
        db_file = self._get_auth_db_file(instance)

        if not db_file:
            return False, "Not Authenticated - User not Setup", None, None

        try:
            conn = sqlite3.connect(db_file)
            cur = conn.cursor()
            row = None
            for query in (
                "SELECT is_revoked, auth, feed_token, broker, name FROM auth LIMIT 1",
            ):
                try:
                    cur.execute(query)
                    row = cur.fetchone()
                    break
                except Exception:
                    continue
            conn.close()

            if not row:
                return False, "Not Authenticated - User not Setup", None, None

            is_revoked, auth, feed_token, broker, name = row
            auth_blank = auth is None or str(auth).strip() == ""
            feed_blank = feed_token is None or str(feed_token).strip() == ""
            broker_blank = broker is None or str(broker).strip() == ""
            name_blank = name is None or str(name).strip() == ""

            if name_blank:
                return False, "Not Authenticated - User not Setup", broker, name
            if is_revoked == 1 and not (auth_blank or feed_blank or broker_blank):
                return False, "Not Authenticated - Invalid Token", broker, name
            if is_revoked == 1:
                return False, "Not Authenticated - User Token Revoked", broker, name
            if broker_blank:
                return False, "Not Authenticated - Invalid Token", broker, name
            if auth_blank or feed_blank:
                return False, "Not Authenticated - Invalid Token", broker, name
            return True, "User Authenticated", broker, name
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

    def _sanitize_instance(self, instance):
        if not instance:
            return None
        instance = instance.strip()
        if instance.startswith("openalgo") and instance[8:].isdigit():
            return instance
        return None

    def _resolve_instance_from_host(self):
        host = self.headers.get("Host", "")
        host = host.split(":", 1)[0].strip()
        if not host:
            return None
        import re
        if not re.match(r"^[A-Za-z0-9.-]+$", host):
            return None
        symlink = f"/var/python/openalgo-flask/openalgo-{host.replace('.', '-')}"
        if os.path.exists(symlink):
            target = os.path.realpath(symlink)
            return self._sanitize_instance(os.path.basename(target))
        return None

    def _resolve_monitor_instance(self):
        instance = self._sanitize_instance(self.headers.get("X-OpenAlgo-Instance"))
        if instance:
            return instance
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)
        instance = self._sanitize_instance(params.get("instance", [None])[0])
        if instance:
            return instance
        return self._resolve_instance_from_host()

    def _require_monitor_instance(self):
        instance = self._resolve_monitor_instance()
        if not instance:
            self.send_json({"error": "Instance not specified"}, 400)
            return None
        return instance
    
    def do_GET(self):
        """Handle GET requests"""
        path = urlparse(self.path).path
        if path == '/monitor' or path == '/monitor/':
            self.serve_monitor_ui()
        elif path == '/monitor/api/health':
            self.handle_monitor_health()
        elif path == '/monitor/api/logs':
            self.handle_monitor_logs()
        elif path == '/monitor/api/status':
            self.handle_monitor_status()
        elif path == '/monitor/api/scripts-status':
            self.handle_scripts_status()
        elif path.startswith('/monitor/api/jobs/'):
            job_id = path.split('/monitor/api/jobs/')[1].strip('/')
            if job_id:
                self.handle_job_status(job_id)
            else:
                self.send_json({"error": "Missing job id"}, 400)
        elif self.path == '/' or self.path == '/index.html':
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
        elif self.path == '/api/scripts-status':
            self.handle_scripts_status()
        elif self.path.startswith('/api/jobs/'):
            job_id = self.path.split('/api/jobs/')[1].strip('/')
            if job_id:
                self.handle_job_status(job_id)
            else:
                self.send_json({"error": "Missing job id"}, 400)
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
        
        path = urlparse(self.path).path
        if path == '/monitor/api/restart':
            instance = self._require_monitor_instance()
            if instance:
                self.handle_restart_instance(instance)
        elif path == '/monitor/api/stop':
            instance = self._require_monitor_instance()
            if instance:
                self.handle_stop_instance(instance)
        elif path == '/monitor/api/start':
            instance = self._require_monitor_instance()
            if instance:
                self.handle_start_instance(instance)
        elif path == '/monitor/api/clear-logs':
            instance = self._require_monitor_instance()
            if instance:
                self.handle_clear_logs_instance(instance)
        elif path == '/monitor/api/invalidate-session':
            instance = self._require_monitor_instance()
            if instance:
                self.handle_invalidate_session(instance)
        elif path == '/monitor/api/reboot-server':
            self.handle_reboot_server()
        elif path == '/monitor/api/health-check':
            self.handle_health_check(data)
        elif path == '/monitor/api/update':
            self.handle_update(data)
        elif path == '/api/invalidate-session':
            instance = data.get('instance', '')
            if instance:
                self.handle_invalidate_session(instance)
            else:
                self.send_json({"error": "Missing instance parameter"}, 400)
        elif self.path == '/api/restart-all':
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
        elif self.path == '/api/health-check':
            self.handle_health_check(data)
        elif self.path == '/api/update':
            self.handle_update(data)
        elif self.path == '/api/scripts-status':
            self.handle_scripts_status()
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

            try:
                health["system"] = self._get_system_stats()
            except Exception:
                health["system"] = None

            self.send_json(health)
        except Exception as e:
            self.send_json({"error": str(e)}, 500)

    def handle_monitor_health(self):
        """Get detailed health status for the monitor instance"""
        instance = self._require_monitor_instance()
        if not instance:
            return
        health = self._get_instance_health(instance)
        try:
            health["system"] = self._get_system_stats()
        except Exception:
            health["system"] = None
        health["timestamp"] = str(datetime.now())
        self.send_json(health)

    def handle_monitor_status(self):
        """Get simple status for the monitor instance"""
        instance = self._require_monitor_instance()
        if not instance:
            return
        health = self._get_instance_health(instance)
        self.send_json({
            "instance": instance,
            "status": health.get("status", "unknown"),
            "timestamp": str(datetime.now())
        })

    def handle_monitor_logs(self):
        """Get logs for the monitor instance"""
        instance = self._require_monitor_instance()
        if not instance:
            return
        self.handle_instance_logs(instance)
    
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

    def handle_clear_logs_instance(self, instance):
        """Clear per-instance log files"""
        try:
            inst_path = f"/var/python/openalgo-flask/{instance}"
            if not os.path.isdir(inst_path):
                self.send_json({"error": "Instance not found", "instance": instance}, 404)
                return

            deleted = 0
            cleared_paths = []
            for log_dir in (f"{inst_path}/log", f"{inst_path}/logs"):
                if os.path.isdir(log_dir):
                    for root, _, files in os.walk(log_dir):
                        for name in files:
                            file_path = os.path.join(root, name)
                            try:
                                os.remove(file_path)
                                deleted += 1
                            except Exception:
                                continue
                    cleared_paths.append(log_dir)

            self.send_json({
                "instance": instance,
                "deleted": deleted,
                "cleared_paths": cleared_paths,
                "message": "Instance log files cleared",
                "timestamp": str(datetime.now())
            })
        except Exception as e:
            self.send_json({
                "instance": instance,
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

    def handle_job_status(self, job_id):
        job = self._get_job(job_id)
        if not job:
            self.send_json({"error": "Job not found"}, 404)
            return
        self.send_json(job)

    def handle_health_check(self, data):
        """Run oa-health-check.sh and return job id"""
        scope = (data.get("scope") or "all").strip().lower()
        instance = data.get("instance")

        if scope not in ("all", "system", "instance"):
            self.send_json({"error": "Invalid scope. Use all|system|instance"}, 400)
            return

        if scope == "instance":
            instance = self._sanitize_instance(instance)
            if not instance:
                self.send_json({"error": "Invalid or missing instance"}, 400)
                return

        script_path = self._find_script("oa-health-check.sh")
        if not script_path:
            self.send_json({"error": "oa-health-check.sh not found"}, 500)
            return

        args = ["all"] if scope == "all" else ["system"] if scope == "system" else [instance]
        job_id = self._create_job("health-check", {"scope": scope, "instance": instance})
        command = ["sudo", "bash", script_path] + args
        Thread(target=self._run_script_job, args=(job_id, command, 300), daemon=True).start()
        self.send_json({
            "status": "queued",
            "job_id": job_id,
            "message": "Health check started",
            "timestamp": self._now_iso()
        })

    def handle_update(self, data):
        """Run oa-update.sh and return job id"""
        scope = (data.get("scope") or "all").strip().lower()
        instance = data.get("instance")

        if scope not in ("all", "instance"):
            self.send_json({"error": "Invalid scope. Use all|instance"}, 400)
            return

        if scope == "instance":
            instance = self._sanitize_instance(instance)
            if not instance:
                self.send_json({"error": "Invalid or missing instance"}, 400)
                return

        script_path = self._find_script("oa-update.sh")
        if not script_path:
            self.send_json({"error": "oa-update.sh not found"}, 500)
            return

        args = ["update-all"] if scope == "all" else [instance]
        job_id = self._create_job("update", {"scope": scope, "instance": instance})
        command = ["sudo", "bash", script_path] + args
        Thread(target=self._run_script_job, args=(job_id, command, 1800), daemon=True).start()
        self.send_json({
            "status": "queued",
            "job_id": job_id,
            "message": "Update started",
            "timestamp": self._now_iso()
        })

    def handle_scripts_status(self):
        script_names = ["oa-health-check.sh", "oa-update.sh", "oa-backup.sh"]
        scripts = {}
        for name in script_names:
            path = self._find_script(name)
            scripts[name] = {"found": bool(path), "path": path}

        missing = [name for name, info in scripts.items() if not info["found"]]

        found_dirs = [os.path.dirname(info["path"]) for info in scripts.values() if info["path"]]
        suggested_dir = None
        if found_dirs:
            counts = {}
            for d in found_dirs:
                counts[d] = counts.get(d, 0) + 1
            suggested_dir = sorted(counts.items(), key=lambda x: (-x[1], x[0]))[0][0]
        else:
            base_dir = os.path.dirname(os.path.abspath(__file__))
            default_root_dir = "/root/Simplifyed-Scripts"
            try:
                if any(name.endswith(".sh") for name in os.listdir(default_root_dir)):
                    suggested_dir = default_root_dir
                elif any(name.endswith(".sh") for name in os.listdir(base_dir)):
                    suggested_dir = base_dir
            except Exception:
                suggested_dir = None

        suggested_fix = None
        if suggested_dir:
            suggested_fix = f"sudo ln -sf \"{suggested_dir}/\"*.sh /usr/local/bin/"

        self.send_json({
            "scripts": scripts,
            "missing": missing,
            "suggested_dir": suggested_dir,
            "suggested_fix": suggested_fix,
            "timestamp": self._now_iso()
        })

    def _get_instance_health(self, instance):
        """Get detailed health info for a single instance"""
        health = {"name": instance, "status": "unknown", "port": None, "database": False, "broker": None, "domain": None, "auth_name": None, "auth_status": None, "session_valid": True, "master_contract": None}

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
            authenticated, last_error, broker_db, name_db = self._read_auth_status(instance)
            health["session_valid"] = authenticated
            if broker_db:
                health["broker"] = broker_db
            if name_db:
                health["auth_name"] = name_db
            if last_error:
                health["auth_status"] = last_error
            elif authenticated:
                health["auth_status"] = "User Authenticated"
        except:
            pass

        try:
            health["master_contract"] = self._get_master_contract_status(instance)
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
        invalidate_result = None
        try:
            invalidate_result = self._invalidate_session(instance)
        except Exception:
            invalidate_result = None
        service_name = self._service_name(instance)
        Thread(target=lambda: subprocess.run(
            f"sudo systemctl restart {service_name}",
            shell=True, capture_output=True, timeout=60
        )).start()
        
        self.send_json({
            "status": "success",
            "message": f"Restart triggered for {instance}",
            "instance": instance,
            "session_invalidated": invalidate_result,
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

    def handle_invalidate_session(self, instance):
        """Invalidate session for a specific instance"""
        result = self._invalidate_session(instance)
        self.send_json({
            "status": "success",
            "message": f"Session invalidated for {instance}",
            "instance": instance,
            "details": result,
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

    def serve_monitor_ui(self):
        """Serve single-instance monitor UI"""
        instance = self._resolve_monitor_instance() or ""
        html = """<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenAlgo Monitor</title>
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
.btn-invalidate{background:#6c757d;color:white}
.btn-invalidate:hover{background:#5a6268}
.btn-reboot{background:#ff6b6b;color:white}
.btn-reboot:hover{background:#ff5252}
.btn-stop{background:#dc3545;color:white}
.btn-start{background:#28a745;color:white}
.btn-invalidate{background:#6c757d;color:white}
.btn-invalidate:hover{background:#5a6268}
.btn-clear{background:#f0ad4e;color:white}
.btn-clear:hover{background:#ec971f}
.btn-small{padding:6px 12px;font-size:12px;margin:2px}
.btn:hover{opacity:0.9;transform:translateY(-2px)}
.btn:disabled{opacity:0.5;cursor:not-allowed;transform:none}
.instance{background:#f8f9fa;padding:15px;margin:10px 0;border-radius:8px;border-left:4px solid #667eea}
.instance-header{display:flex;justify-content:space-between;align-items:center}
.instance-name{font-weight:600;color:#333;font-size:16px}
.instance-details{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin-top:10px;padding-top:10px;border-top:1px solid #e0e0e0}
.detail-item{font-size:13px}
.detail-label{color:#666;font-weight:500}
.detail-value{color:#333;font-weight:600;margin-top:2px}
.active{color:#28a745}
.inactive{color:#dc3545}
.badge{padding:4px 8px;border-radius:4px;font-size:12px;font-weight:600;margin-left:10px}
.badge-active{background:#d4edda;color:#155724}
.badge-inactive{background:#f8d7da;color:#721c24}
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
.actions{display:flex;gap:5px;flex-wrap:wrap;margin-top:10px;justify-content:flex-end}
.broker-status{margin-top:10px;padding:10px;background:#fff;border-radius:4px;border-left:3px solid #667eea;font-size:13px}
.master-contract{margin-top:10px;padding:10px;background:#fff;border-radius:4px;border-left:3px solid #28a745;font-size:13px}
.master-details{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:8px;margin-top:8px}
.master-contract{margin-top:10px;padding:10px;background:#fff;border-radius:4px;border-left:3px solid #28a745;font-size:13px}
.master-details{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:8px;margin-top:8px}
.master-contract{margin-top:10px;padding:10px;background:#fff;border-radius:4px;border-left:3px solid #28a745;font-size:13px}
.master-details{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:8px;margin-top:8px}
.logs-toggle{padding:8px 12px;background:#667eea;color:white;border:none;border-radius:4px;cursor:pointer;font-size:12px;margin-top:10px;width:100%}
.logs-toggle:hover{background:#5568d3}
.logs-section{display:none;margin-top:10px;padding:10px;background:#1e1e1e;border-radius:4px;border:1px solid #ccc}
.logs-section.show{display:block}
.logs-container{max-height:500px;overflow-y:auto;font-family:'Courier New',monospace;font-size:11px;color:#d4d4d4;line-height:1.4}
.log-line{padding:2px 5px;word-break:break-all}
.log-error{background:#c4444466;color:#ff6b6b}
.log-success{background:#22863a66;color:#85e89d}
.toolbar{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:10px}
.toolbar .btn-primary{width:auto}
.system-card{background:#f8f9fa;padding:15px;border-radius:8px;margin-bottom:20px;border-left:4px solid #28a745}
.system-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:10px;margin-top:10px}
.system-item{font-size:13px}
.system-label{color:#666;font-weight:500}
.system-value{color:#333;font-weight:600;margin-top:2px}
.maintenance{background:#f8f9fa;padding:15px;border-radius:8px;margin:15px 0;border-left:4px solid #17a2b8}
.maintenance-actions{display:flex;gap:8px;flex-wrap:wrap;margin:10px 0}
.maintenance-actions .btn{flex:1 1 0;min-width:180px;width:auto}
.manager-toolbar{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:10px}
.manager-toolbar .btn{flex:1 1 0;min-width:180px;width:auto}
.maintenance-output{display:none;margin-top:10px;background:#1e1e1e;border-radius:6px;border:1px solid #333;padding:10px;max-height:400px;overflow:auto}
.maintenance-output pre{color:#d4d4d4;font-family:'Courier New',monospace;font-size:11px;line-height:1.4;white-space:pre-wrap;word-break:break-word}
.maintenance-status{font-size:12px;color:#555}
.scripts-status{display:flex;gap:12px;flex-wrap:wrap}
.scripts-status{display:flex;gap:12px;flex-wrap:wrap}
.btn-update{background:#17a2b8;color:white}
.btn-update:hover{background:#138496}
.btn-health{background:#20c997;color:white}
.btn-health:hover{background:#18a17a}
</style>
</head>
<body>
<div class="container">
<div class="header">
<h1>🚀 OpenAlgo Monitor</h1>
<p>Manage your OpenAlgo instance</p>
</div>
<div class="content">
<div id="alert" class="alert"></div>
<div class="toolbar">
<button class="btn btn-primary" style="background:#28a745" onclick="loadInstance()">🔄 Refresh</button>
<button class="btn btn-primary btn-restart" onclick="restartInstance()">🔄 Restart Instance</button>
<button class="btn btn-primary btn-reboot" onclick="rebootServer()">⚡ Reboot Server</button>
<button class="btn btn-primary btn-clear" onclick="clearLogs()">🧹 Clear Logs</button>
<button class="btn btn-primary btn-clear" style="background:#6c757d" onclick="invalidateSession()">🚫 Invalidate Session</button>
</div>
<div id="system" class="system-card"></div>
<div class="maintenance">
<h3>Maintenance</h3>
<div id="scripts-status" class="maintenance-status scripts-status"></div>
<div class="maintenance-actions">
<button id="btn-health-instance" class="btn btn-primary btn-health" onclick="runHealthCheck()">🩺 Health Check</button>
<button id="btn-update-instance" class="btn btn-primary btn-update" onclick="updateInstance()">⬆ Update Instance</button>
</div>
<div id="maintenance-status" class="maintenance-status"></div>
<div id="maintenance-output" class="maintenance-output"><pre id="maintenance-output-pre"></pre></div>
</div>
<div id="loading" class="loading"><div class="spinner"></div><p>Loading instance...</p></div>
<div id="instance"></div>
</div>
</div>

<script>
const monitorInstance="__INSTANCE__";
let resolvedInstance=null;
let logsLoaded=false;
const monitorApiBase='/monitor/api';
async function fetchJson(url, options){
const r=await fetch(url,options);
const text=await r.text();
const contentType=(r.headers.get('content-type')||'').toLowerCase();
try{
return JSON.parse(text);
}catch(e){
const preview=text.replace(/\\s+/g,' ').slice(0,160);
throw new Error(`Invalid JSON from ${url} (status ${r.status}, type ${contentType||'unknown'}): ${preview}`);
}
}
async function loadInstance(){
if(!monitorInstance){
showAlert('Instance not specified. Use /monitor?instance=openalgo1','error');
document.getElementById('loading').style.display='none';
return;
}
try{
document.getElementById('loading').style.display='block';
const h=await fetchJson(`${monitorApiBase}/health`);
const scriptsStatus=await fetchJson(`${monitorApiBase}/scripts-status`);
document.getElementById('loading').style.display='none';
if(h.error){
showAlert(h.error,'error');
return;
}
renderSystem(h.system);
renderScriptsStatus(scriptsStatus);
renderInstance(h);
}catch(e){
showAlert('Error: '+e.message,'error');
}
}
function renderScriptsStatus(data){
const el=document.getElementById('scripts-status');
if(!el||!data||!data.scripts){
return;
}
const items=Object.entries(data.scripts).map(([name,info])=>{
const ok=info&&info.found;
return `<span>${ok?'✅':'❌'} ${name}</span>`;
}).join('');
let extra='';
if(data.missing&&data.missing.length){
const fix=data.suggested_fix||'sudo ln -sf /path/to/openalgo-scripts/*.sh /usr/local/bin/';
extra=`<div style="margin-top:6px"><strong>Fix:</strong> <code>${escapeHtml(fix)}</code></div>`;
}
el.innerHTML=(items||'')+extra;
applyScriptsAvailability(data.scripts);
}
function applyScriptsAvailability(scripts){
const healthOk=!!(scripts&&scripts['oa-health-check.sh']&&scripts['oa-health-check.sh'].found);
const updateOk=!!(scripts&&scripts['oa-update.sh']&&scripts['oa-update.sh'].found);
const btnHealth=document.getElementById('btn-health-instance');
const btnUpdate=document.getElementById('btn-update-instance');
if(btnHealth){btnHealth.disabled=!healthOk;btnHealth.title=healthOk?'':'oa-health-check.sh not found';}
if(btnUpdate){btnUpdate.disabled=!updateOk;btnUpdate.title=updateOk?'':'oa-update.sh not found';}
}
function renderInstance(h){
const inst=h.name||monitorInstance;
resolvedInstance=inst||resolvedInstance;
const active=h.status==='active';
const broker=h.broker||'Unknown';
const domain=h.domain||'Unknown';
const authName=h.auth_name||'Unknown';
const authStatus=h.auth_status||((h.session_valid!==false)?'User Authenticated':'Not Authenticated');
const isAuthenticated=authStatus==='User Authenticated';
const brokerAuthBadge=isAuthenticated?`<span class="badge badge-authenticated">${authStatus}</span>`:`<span class="badge badge-unauthenticated">${authStatus}</span>`;
const mc=h.master_contract||{};
const mcReady=mc.is_ready===true;
const mcStatus=mc.status||'Master Contract Data Not Ready';
const mcBadge=mcReady?`<span class="badge badge-authenticated">${mcStatus}</span>`:`<span class="badge badge-unauthenticated">${mcStatus}</span>`;
const mcLast=mc.last_updated||'Unknown';
const mcSymbols=(mc.total_symbols!==undefined&&mc.total_symbols!==null)?mc.total_symbols:'N/A';
const mcBroker=mc.broker||'Unknown';
const mcMessage=mc.message||'N/A';
const actions=active
?`<button class="btn btn-small btn-stop" onclick="stopInstance()">⏹ Stop</button>`
:`<button class="btn btn-small btn-start" onclick="startInstance()">▶ Start</button>`;
document.getElementById('instance').innerHTML=`<div class="instance"><div class="instance-header"><div><div class="instance-name">${inst}<span class="badge ${active?'badge-active':'badge-inactive'}">${active?'✓ Active':'✗ Inactive'}</span></div></div></div><div class="instance-details"><div class="detail-item"><div class="detail-label">Domain</div><div class="detail-value">${domain}</div></div><div class="detail-item"><div class="detail-label">Status</div><div class="detail-value ${active?'active':'inactive'}">${h.status||'unknown'}</div></div><div class="detail-item"><div class="detail-label">Flask Port</div><div class="detail-value">${h.port||'N/A'}</div></div><div class="detail-item"><div class="detail-label">Database</div><div class="detail-value">${h.database?'✓ Present':'✗ Missing'}</div></div></div><div class="broker-status"><strong>${authName}</strong> | <strong>Broker:</strong> ${broker} | ${brokerAuthBadge}</div><div class="master-contract" style="border-left-color:${mcReady?'#28a745':'#dc3545'}"><strong>Master Contract Data</strong> | ${mcBadge}<div class="master-details"><div><div class="detail-label">Last Updated</div><div class="detail-value">${mcLast}</div></div><div><div class="detail-label">Total Symbols</div><div class="detail-value">${mcSymbols}</div></div><div><div class="detail-label">Broker</div><div class="detail-value">${mcBroker}</div></div><div><div class="detail-label">Message</div><div class="detail-value">${mcMessage}</div></div></div></div><button class="logs-toggle" onclick="toggleLogs()">📋 View Logs</button><div id="logs" class="logs-section"><div class="logs-container" id="logs-content"><p style="color:#999">Loading logs...</p></div></div><div class="actions"><button class="btn btn-small btn-restart" onclick="restartInstance()">🔄 Restart</button>${actions}</div></div>`;
}
function toggleLogs(){
const logsSection=document.getElementById('logs');
if(!logsSection)return;
logsSection.classList.toggle('show');
if(logsSection.classList.contains('show')&&!logsLoaded){
fetchLogs();
}
}
async function fetchLogs(){
try{
const data=await fetchJson(`${monitorApiBase}/logs`);
const logsContent=document.getElementById('logs-content');
if(data.logs&&data.logs.length>0){
const html=data.logs.map(log=>{
const lowerLog=log.toLowerCase();
const hasAuthError=(lowerLog.includes('session expired')||lowerLog.includes('invalid session detected')||lowerLog.includes('no valid auth token'));
const hasSuccess=(lowerLog.includes('master contract download completed')||lowerLog.includes('successfully loaded'));
return`<div class="log-line ${hasAuthError?'log-error':''}${hasSuccess?'log-success':''}">${escapeHtml(log)}</div>`;
}).join('');
logsContent.innerHTML=html;
logsLoaded=true;
}else{
logsContent.innerHTML='<p style="color:#999">No logs available</p>';
}
}catch(e){
document.getElementById('logs-content').innerHTML=`<p style="color:#ff6b6b">Error loading logs: ${e.message}</p>`;
}
}
function escapeHtml(text){
const map={'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'};
return text.replace(/[&<>"']/g,m=>map[m]);
}
function formatBytes(bytes){
if(bytes===null||bytes===undefined)return 'N/A';
const gb=bytes/1024/1024/1024;
return gb.toFixed(1)+' GB';
}
function formatPercent(p){
if(p===null||p===undefined)return 'N/A';
return p.toFixed(1)+'%';
}
function renderSystem(sys){
const el=document.getElementById('system');
if(!sys){
el.innerHTML='<h3>System</h3><p style="color:#999">System stats unavailable</p>';
return;
}
el.innerHTML=`<h3>System</h3>
<div class="system-grid">
<div class="system-item"><div class="system-label">CPU</div><div class="system-value">${formatPercent(sys.cpu_percent)}</div></div>
<div class="system-item"><div class="system-label">Load Avg</div><div class="system-value">${sys.load1??'N/A'} / ${sys.load5??'N/A'} / ${sys.load15??'N/A'}</div></div>
<div class="system-item"><div class="system-label">RAM Used</div><div class="system-value">${formatBytes(sys.mem_used)} / ${formatBytes(sys.mem_total)} (${formatPercent(sys.mem_percent)})</div></div>
<div class="system-item"><div class="system-label">Swap Used</div><div class="system-value">${formatBytes(sys.swap_used)} / ${formatBytes(sys.swap_total)} (${formatPercent(sys.swap_percent)})</div></div>
<div class="system-item"><div class="system-label">Storage Used</div><div class="system-value">${formatBytes(sys.disk_used)} / ${formatBytes(sys.disk_total)} (${formatPercent(sys.disk_percent)})</div></div>
</div>`;
}
async function post(path){
return fetchJson(path,{method:'POST'});
}
async function restartInstance(){
if(!confirm('Restart this instance? This will invalidate the session.'))return;
showAlert('Restarting instance and invalidating session...','info');
await post('/monitor/api/restart');
setTimeout(loadInstance,1000);
}
async function stopInstance(){
if(!confirm('Stop this instance?'))return;
showAlert('Stopping instance...','info');
await post('/monitor/api/stop');
setTimeout(loadInstance,1000);
}
async function startInstance(){
if(!confirm('Start this instance?'))return;
showAlert('Starting instance...','info');
await post('/monitor/api/start');
setTimeout(loadInstance,1000);
}
async function clearLogs(){
if(!confirm('Clear all log files for this instance?'))return;
showAlert('Clearing logs...','info');
await post('/monitor/api/clear-logs');
logsLoaded=false;
setTimeout(loadInstance,1000);
}
async function invalidateSession(){
if(!confirm('Invalidate the session for this instance? This will clear auth tokens and revoke the session.'))return;
showAlert('Invalidating session...','info');
await post('/monitor/api/invalidate-session');
setTimeout(loadInstance,1000);
}
async function rebootServer(){
if(!confirm('⚠️ Reboot the server? This will reboot all instances on this server.'))return;
if(!confirm('⚠️ FINAL CONFIRMATION: The server will restart now. Continue?'))return;
showAlert('Rebooting server... Connection will be lost shortly.','info');
try{
const r=await fetch('/monitor/api/reboot-server',{method:'POST'});
const d=await r.json();
showAlert(d.message,'success');
}catch(e){
showAlert('Reboot initiated (API connection lost as expected)','success');
}
}
function showMaintenanceStatus(text){
const statusEl=document.getElementById('maintenance-status');
if(statusEl){statusEl.textContent=text||'';}
}
function showMaintenanceOutput(title,status,exitCode,output){
const outputEl=document.getElementById('maintenance-output');
const preEl=document.getElementById('maintenance-output-pre');
const statusText=exitCode!==null&&exitCode!==undefined?`${status} (exit ${exitCode})`:status;
showMaintenanceStatus(`${title} - ${statusText}`);
if(outputEl){outputEl.style.display='block';}
if(preEl){preEl.innerHTML=escapeHtml(output||'No output');}
}
async function pollJob(jobId,title){
try{
const job=await fetchJson(`${monitorApiBase}/jobs/${jobId}`);
if(job.error){
showAlert(job.error,'error');
showMaintenanceOutput(title,'error',null,job.error);
return;
}
if(job.status==='running'||job.status==='queued'){
showMaintenanceStatus(`${title} - ${job.status}...`);
const preEl=document.getElementById('maintenance-output-pre');
const outputEl=document.getElementById('maintenance-output');
if(outputEl){outputEl.style.display='block';}
if(preEl){preEl.innerHTML=escapeHtml(job.output||'Running...');}
setTimeout(()=>pollJob(jobId,title),2000);
return;
}
const message=job.output||job.error||'No output';
showMaintenanceOutput(title,job.status,job.exit_code,message);
}catch(e){
showAlert('Error: '+e.message,'error');
showMaintenanceOutput(title,'error',null,e.message);
}
}
async function startJob(endpoint,payload,title){
showMaintenanceStatus(`${title} - starting...`);
const outputEl=document.getElementById('maintenance-output');
const preEl=document.getElementById('maintenance-output-pre');
if(outputEl){outputEl.style.display='block';}
if(preEl){preEl.innerHTML='Starting...';}
const data=await fetchJson(endpoint,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload||{})});
if(data.error){
showAlert(data.error,'error');
showMaintenanceOutput(title,'error',null,data.error);
return;
}
pollJob(data.job_id,title);
}
function runHealthCheck(){
const target=resolvedInstance||monitorInstance;
if(!target){
showAlert('Instance not specified. Use /monitor?instance=openalgo1','error');
return;
}
startJob(`${monitorApiBase}/health-check`,{scope:'instance',instance:target},`Health Check (${target})`);
}
function updateInstance(){
const target=resolvedInstance||monitorInstance;
if(!target){
showAlert('Instance not specified. Use /monitor?instance=openalgo1','error');
return;
}
if(!confirm(`Update ${target}? This can take several minutes.`))return;
startJob(`${monitorApiBase}/update`,{scope:'instance',instance:target},`Update ${target}`);
}
function showAlert(msg,type){
const a=document.getElementById('alert');
a.textContent=msg;
a.className=`alert alert-${type} show`;
if(type!=='error')setTimeout(()=>a.classList.remove('show'),4000);
}
window.addEventListener('load',loadInstance);
setInterval(loadInstance,30000);
</script>
</body>
</html>"""

        html = html.replace("__INSTANCE__", instance)
        html_bytes = html.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate')
        self.send_header('Pragma', 'no-cache')
        self.send_header('Expires', '0')
        self.send_header('Content-Length', len(html_bytes))
        self.end_headers()
        self.wfile.write(html_bytes)

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
.system-card{background:#f8f9fa;padding:15px;border-radius:8px;margin-bottom:20px;border-left:4px solid #28a745}
.system-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:10px;margin-top:10px}
.system-item{font-size:13px}
.system-label{color:#666;font-weight:500}
.system-value{color:#333;font-weight:600;margin-top:2px}
.actions{display:flex;gap:5px;flex-wrap:wrap;margin-top:10px;justify-content:flex-end}
.maintenance{background:#f8f9fa;padding:15px;border-radius:8px;margin:15px 0;border-left:4px solid #17a2b8}
.maintenance-actions{display:flex;gap:8px;flex-wrap:wrap;margin:10px 0}
.maintenance-output{display:none;margin-top:10px;background:#1e1e1e;border-radius:6px;border:1px solid #333;padding:10px;max-height:400px;overflow:auto}
.maintenance-output pre{color:#d4d4d4;font-family:'Courier New',monospace;font-size:11px;line-height:1.4;white-space:pre-wrap;word-break:break-word}
.maintenance-status{font-size:12px;color:#555}
.btn-update{background:#17a2b8;color:white}
.btn-update:hover{background:#138496}
.btn-health{background:#20c997;color:white}
.btn-health:hover{background:#18a17a}
.broker-status{margin-top:10px;padding:10px;background:#fff;border-radius:4px;border-left:3px solid #667eea;font-size:13px}
.master-contract{margin-top:10px;padding:10px;background:#fff;border-radius:4px;border-left:3px solid #28a745;font-size:13px}
.master-details{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:8px;margin-top:8px}
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
<div id="system" class="system-card"></div>
<div class="maintenance">
<h3>Maintenance</h3>
<div id="scripts-status" class="maintenance-status scripts-status"></div>
<div class="maintenance-actions">
<button id="btn-health-all" class="btn btn-primary btn-health" onclick="runHealthCheck('all')">🩺 Health Check (All)</button>
<button id="btn-health-system" class="btn btn-primary btn-health" onclick="runHealthCheck('system')">🧩 Health Check (System)</button>
<button id="btn-update-all" class="btn btn-primary btn-update" onclick="updateAll()">⬆️ Update All Instances</button>
</div>
<div id="maintenance-status" class="maintenance-status"></div>
<div id="maintenance-output" class="maintenance-output"><pre id="maintenance-output-pre"></pre></div>
</div>
<div class="manager-toolbar">
<button class="btn btn-primary" onclick="restartAll()">🔄 Restart All Instances</button>
<button class="btn btn-primary" style="background:#28a745" onclick="loadInstances()">🔄 Refresh</button>
<button class="btn btn-primary btn-reboot" onclick="rebootServer()">⚡ Reboot Server</button>
</div>
<div id="loading" class="loading"><div class="spinner"></div><p>Loading instances...</p></div>
<div id="instances"></div>
</div>
</div>

<script>
let brokerStatusCache={};
let logsCache={};
async function fetchJson(url, options){
const r=await fetch(url,options);
const text=await r.text();
const contentType=(r.headers.get('content-type')||'').toLowerCase();
try{
return JSON.parse(text);
}catch(e){
const preview=text.replace(/\\s+/g,' ').slice(0,160);
throw new Error(`Invalid JSON from ${url} (status ${r.status}, type ${contentType||'unknown'}): ${preview}`);
}
}
async function loadInstances(){
try{
document.getElementById('loading').style.display='block';
const instances=await fetchJson('/api/instances');
const health=await fetchJson('/api/health');
const scriptsStatus=await fetchJson('/api/scripts-status');
document.getElementById('loading').style.display='none';
if(!instances||instances.length===0){
document.getElementById('instances').innerHTML='<p>No instances found</p>';
return;
}
const running=Object.values(health.instances||{}).filter(i=>i.status==='active').length;
document.getElementById('summary').innerHTML=`<p><strong>Total Instances:</strong> ${instances.length} | <strong>Running:</strong> <span class="active">${running}</span> | <strong>Stopped:</strong> <span class="inactive">${instances.length-running}</span></p>`;
renderSystem(health.system);
renderScriptsStatus(scriptsStatus);
const html=instances.map(inst=>{
const h=health.instances?.[inst]||{};
const active=h.status==='active';
const broker=h.broker||'Unknown';
const domain=h.domain||'Unknown';
const authName=h.auth_name||'Unknown';
const authStatus=h.auth_status||((h.session_valid!==false)?'User Authenticated':'Not Authenticated');
const isAuthenticated=authStatus==='User Authenticated';
const brokerAuthBadge=isAuthenticated?`<span class="badge badge-authenticated">${authStatus}</span>`:`<span class="badge badge-unauthenticated">${authStatus}</span>`;
const mc=h.master_contract||{};
const mcReady=mc.is_ready===true;
const mcStatus=mc.status||'Master Contract Data Not Ready';
const mcBadge=mcReady?`<span class="badge badge-authenticated">${mcStatus}</span>`:`<span class="badge badge-unauthenticated">${mcStatus}</span>`;
const mcLast=mc.last_updated||'Unknown';
const mcSymbols=(mc.total_symbols!==undefined&&mc.total_symbols!==null)?mc.total_symbols:'N/A';
const mcBroker=mc.broker||'Unknown';
const mcMessage=mc.message||'N/A';
return`<div class="instance"><div class="instance-header"><div><div class="instance-name">${inst}<span class="badge ${active?'badge-active':'badge-inactive'}">${active?'✓ Active':'✗ Inactive'}</span></div></div></div><div class="instance-details"><div class="detail-item"><div class="detail-label">Domain</div><div class="detail-value">${domain}</div></div><div class="detail-item"><div class="detail-label">Status</div><div class="detail-value ${active?'active':'inactive'}">${h.status||'unknown'}</div></div><div class="detail-item"><div class="detail-label">Flask Port</div><div class="detail-value">${h.port||'N/A'}</div></div><div class="detail-item"><div class="detail-label">Database</div><div class="detail-value">${h.database?'✓ Present':'✗ Missing'}</div></div></div><div class="broker-status"><strong>${authName}</strong> | <strong>Broker:</strong> ${broker} | ${brokerAuthBadge}</div><div class="master-contract" style="border-left-color:${mcReady?'#28a745':'#dc3545'}"><strong>Master Contract Data</strong> | ${mcBadge}<div class="master-details"><div><div class="detail-label">Last Updated</div><div class="detail-value">${mcLast}</div></div><div><div class="detail-label">Total Symbols</div><div class="detail-value">${mcSymbols}</div></div><div><div class="detail-label">Broker</div><div class="detail-value">${mcBroker}</div></div><div><div class="detail-label">Message</div><div class="detail-value">${mcMessage}</div></div></div></div><button class="logs-toggle" onclick="toggleLogs('${inst}')">📋 View Logs</button><div id="logs-${inst}" class="logs-section"><div class="logs-container" id="logs-content-${inst}"><p style="color:#999">Loading logs...</p></div></div><div class="actions"><button class="btn btn-small btn-health" onclick="runHealthCheck('instance','${inst}')">🩺 Health</button><button class="btn btn-small btn-update" onclick="updateInstance('${inst}')">⬆ Update</button><button class="btn btn-small btn-restart" onclick="restart('${inst}')">🔄 Restart</button><button class="btn btn-small btn-invalidate" onclick="invalidate('${inst}')">🚫 Invalidate</button>${active?`<button class="btn btn-small btn-stop" onclick="stop('${inst}')">⏹ Stop</button>`:`<button class="btn btn-small btn-start" onclick="start('${inst}')">▶ Start</button>`}</div></div>`;
}).join('');
document.getElementById('instances').innerHTML=html;
}catch(e){
showAlert('Error: '+e.message,'error');
}
}
function renderScriptsStatus(data){
const el=document.getElementById('scripts-status');
if(!el||!data||!data.scripts){
return;
}
const items=Object.entries(data.scripts).map(([name,info])=>{
const ok=info&&info.found;
return `<span>${ok?'✅':'❌'} ${name}</span>`;
}).join('');
let extra='';
if(data.missing&&data.missing.length){
const fix=data.suggested_fix||'sudo ln -sf /path/to/openalgo-scripts/*.sh /usr/local/bin/';
extra=`<div style="margin-top:6px"><strong>Fix:</strong> <code>${escapeHtml(fix)}</code></div>`;
}
el.innerHTML=(items||'')+extra;
applyScriptsAvailability(data.scripts);
}
function applyScriptsAvailability(scripts){
const healthOk=!!(scripts&&scripts['oa-health-check.sh']&&scripts['oa-health-check.sh'].found);
const updateOk=!!(scripts&&scripts['oa-update.sh']&&scripts['oa-update.sh'].found);
const btnHealthAll=document.getElementById('btn-health-all');
const btnHealthSystem=document.getElementById('btn-health-system');
const btnUpdateAll=document.getElementById('btn-update-all');
if(btnHealthAll){btnHealthAll.disabled=!healthOk;btnHealthAll.title=healthOk?'':'oa-health-check.sh not found';}
if(btnHealthSystem){btnHealthSystem.disabled=!healthOk;btnHealthSystem.title=healthOk?'':'oa-health-check.sh not found';}
if(btnUpdateAll){btnUpdateAll.disabled=!updateOk;btnUpdateAll.title=updateOk?'':'oa-update.sh not found';}
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
const data=await fetchJson(`/api/logs/${inst}`);
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
function formatBytes(bytes){
if(bytes===null||bytes===undefined)return 'N/A';
const gb=bytes/1024/1024/1024;
return gb.toFixed(1)+' GB';
}
function formatPercent(p){
if(p===null||p===undefined)return 'N/A';
return p.toFixed(1)+'%';
}
function renderSystem(sys){
const el=document.getElementById('system');
if(!sys){
el.innerHTML='<h3>System</h3><p style="color:#999">System stats unavailable</p>';
return;
}
el.innerHTML=`<h3>System</h3>
<div class="system-grid">
<div class="system-item"><div class="system-label">CPU</div><div class="system-value">${formatPercent(sys.cpu_percent)}</div></div>
<div class="system-item"><div class="system-label">Load Avg</div><div class="system-value">${sys.load1??'N/A'} / ${sys.load5??'N/A'} / ${sys.load15??'N/A'}</div></div>
<div class="system-item"><div class="system-label">RAM Used</div><div class="system-value">${formatBytes(sys.mem_used)} / ${formatBytes(sys.mem_total)} (${formatPercent(sys.mem_percent)})</div></div>
<div class="system-item"><div class="system-label">Swap Used</div><div class="system-value">${formatBytes(sys.swap_used)} / ${formatBytes(sys.swap_total)} (${formatPercent(sys.swap_percent)})</div></div>
<div class="system-item"><div class="system-label">Storage Used</div><div class="system-value">${formatBytes(sys.disk_used)} / ${formatBytes(sys.disk_total)} (${formatPercent(sys.disk_percent)})</div></div>
</div>`;
}
async function restartAll(){
if(!confirm('Restart all instances?'))return;
showAlert('Restarting all...','info');
const d=await fetchJson('/api/restart-all',{method:'POST'});
showAlert(d.message,'success');
setTimeout(loadInstances,2000);
}
function showMaintenanceStatus(text){
const statusEl=document.getElementById('maintenance-status');
if(statusEl){statusEl.textContent=text||'';}
}
function showMaintenanceOutput(title,status,exitCode,output){
const outputEl=document.getElementById('maintenance-output');
const preEl=document.getElementById('maintenance-output-pre');
const statusText=exitCode!==null&&exitCode!==undefined?`${status} (exit ${exitCode})`:status;
showMaintenanceStatus(`${title} - ${statusText}`);
if(outputEl){outputEl.style.display='block';}
if(preEl){preEl.innerHTML=escapeHtml(output||'No output');}
}
async function pollJob(jobId,title){
try{
const job=await fetchJson(`/api/jobs/${jobId}`);
if(job.error){
showAlert(job.error,'error');
showMaintenanceOutput(title,'error',null,job.error);
return;
}
if(job.status==='running'||job.status==='queued'){
showMaintenanceStatus(`${title} - ${job.status}...`);
const preEl=document.getElementById('maintenance-output-pre');
const outputEl=document.getElementById('maintenance-output');
if(outputEl){outputEl.style.display='block';}
if(preEl){preEl.innerHTML=escapeHtml(job.output||'Running...');}
setTimeout(()=>pollJob(jobId,title),2000);
return;
}
const message=job.output||job.error||'No output';
showMaintenanceOutput(title,job.status,job.exit_code,message);
}catch(e){
showAlert('Error: '+e.message,'error');
showMaintenanceOutput(title,'error',null,e.message);
}
}
async function startJob(endpoint,payload,title){
showMaintenanceStatus(`${title} - starting...`);
const outputEl=document.getElementById('maintenance-output');
const preEl=document.getElementById('maintenance-output-pre');
if(outputEl){outputEl.style.display='block';}
if(preEl){preEl.innerHTML='Starting...';}
const data=await fetchJson(endpoint,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload||{})});
if(data.error){
showAlert(data.error,'error');
showMaintenanceOutput(title,'error',null,data.error);
return;
}
pollJob(data.job_id,title);
}
function runHealthCheck(scope,instance){
const title=scope==='instance'?`Health Check (${instance})`:`Health Check (${scope})`;
startJob('/api/health-check',{scope:scope,instance:instance},title);
}
function updateAll(){
if(!confirm('Update ALL instances? This can take several minutes.'))return;
startJob('/api/update',{scope:'all'},'Update All Instances');
}
function updateInstance(inst){
if(!confirm(`Update ${inst}? This can take several minutes.`))return;
startJob('/api/update',{scope:'instance',instance:inst},`Update ${inst}`);
}
async function restart(inst){
if(!confirm(`Restart ${inst}? This will invalidate the session.`))return;
await fetchJson('/api/restart-instance',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({instance:inst})});
showAlert(`Restarting ${inst}`,'info');
setTimeout(loadInstances,1000);
}
async function invalidate(inst){
if(!confirm(`Invalidate session for ${inst}? This will clear auth tokens and revoke the session.`))return;
await fetchJson('/api/invalidate-session',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({instance:inst})});
showAlert(`Invalidating session for ${inst}`,'info');
setTimeout(loadInstances,1000);
}
async function stop(inst){
if(!confirm(`Stop ${inst}?`))return;
await fetchJson('/api/stop-instance',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({instance:inst})});
showAlert(`Stopping ${inst}`,'info');
setTimeout(loadInstances,1000);
}
async function start(inst){
if(!confirm(`Start ${inst}?`))return;
await fetchJson('/api/start-instance',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({instance:inst})});
showAlert(`Starting ${inst}`,'info');
setTimeout(loadInstances,1000);
}
async function rebootServer(){
if(!confirm('⚠️ Are you sure you want to reboot the server? This will disconnect all instances!'))return;
if(!confirm('⚠️ FINAL CONFIRMATION: The server will restart now. Continue?'))return;
showAlert('Rebooting server... Connection will be lost shortly.','info');
try{
const d=await fetchJson('/api/reboot-server',{method:'POST'});
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
        
        html_bytes = html.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate')
        self.send_header('Pragma', 'no-cache')
        self.send_header('Expires', '0')
        self.send_header('Content-Length', len(html_bytes))
        self.end_headers()
        self.wfile.write(html_bytes)
    
    def send_json(self, data, status=200):
        """Send JSON response"""
        json_str = json.dumps(data)
        json_bytes = json_str.encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate')
        self.send_header('Pragma', 'no-cache')
        self.send_header('Expires', '0')
        self.send_header('Content-Length', len(json_bytes))
        self.end_headers()
        self.wfile.write(json_bytes)
    
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
