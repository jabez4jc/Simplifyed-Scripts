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

_SERVER_IP_CACHE = None


def get_server_ip():
    """Best-effort primary outbound IP, same convention as api-manager.sh's `hostname -I`."""
    global _SERVER_IP_CACHE
    if _SERVER_IP_CACHE is None:
        try:
            out = subprocess.check_output(['hostname', '-I'], text=True, timeout=2).strip()
            _SERVER_IP_CACHE = out.split()[0] if out else ''
        except Exception:
            _SERVER_IP_CACHE = ''
    return _SERVER_IP_CACHE


DASHBOARD_CSS = """
:root{
--bg:#0a0e17;--bg-elev:#0e1420;--surface:#121a29;--surface-2:#182135;--border:#232e44;--border-soft:#1b2438;
--text:#e8ecf5;--text-dim:#94a2b9;--text-faint:#8291a8;
--accent:#5b8cff;--accent-soft:rgba(91,140,255,.12);
--success:#2fd8a6;--success-soft:rgba(47,216,166,.12);
--warning:#f2b84b;--warning-soft:rgba(242,184,75,.12);
--danger:#f4586e;--danger-soft:rgba(244,88,110,.12);
--info:#4bb8f0;--info-soft:rgba(75,184,240,.12);
--radius:12px;--radius-sm:8px;
--shadow:0 1px 2px rgba(0,0,0,.35),0 12px 28px -12px rgba(0,0,0,.55);
--font:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;
--mono:ui-monospace,SFMono-Regular,'SF Mono',Menlo,Consolas,monospace;
}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:var(--font);background:var(--bg);color:var(--text);min-height:100vh;-webkit-font-smoothing:antialiased}
a{color:var(--accent)}
::selection{background:var(--accent-soft)}
.topbar{position:sticky;top:0;z-index:50;display:flex;align-items:center;justify-content:space-between;gap:10px;height:56px;padding:0 20px;background:rgba(14,20,32,.85);backdrop-filter:blur(10px);border-bottom:1px solid var(--border);overflow:hidden}
.brand{display:flex;align-items:center;gap:10px;min-width:0}
.brand-mark{width:28px;height:28px;border-radius:8px;background:linear-gradient(135deg,#5b8cff,#8a5bff);display:flex;align-items:center;justify-content:center;color:#fff;flex:none}
.brand-text{display:flex;flex-direction:column;line-height:1.15;min-width:0}
.brand-text b{font-size:13.5px;font-weight:650;letter-spacing:-.01em}
.brand-text span{font-size:11px;color:var(--text-faint);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.topbar-right{display:flex;align-items:center;gap:14px;flex:none}
.live{display:flex;align-items:center;gap:6px;font-size:12px;color:var(--text-dim);white-space:nowrap}
.dot{width:7px;height:7px;border-radius:50%;background:var(--success);box-shadow:0 0 0 3px var(--success-soft)}
.dot.pulse{animation:pulse 2s ease-in-out infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.45}}
.icon-btn{display:inline-flex;align-items:center;justify-content:center;width:32px;height:32px;border-radius:var(--radius-sm);border:1px solid var(--border);background:var(--surface-2);color:var(--text-dim);cursor:pointer;transition:.15s ease}
.icon-btn:hover{color:var(--text);border-color:#324063;background:#1c2740}
.icon-btn:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
main{max-width:1360px;margin:0 auto;padding:24px 20px 64px;display:flex;flex-direction:column;gap:18px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);box-shadow:var(--shadow)}
.card-head{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:16px 20px;border-bottom:1px solid var(--border-soft)}
.card-head h2{font-size:14.5px;font-weight:600;display:flex;align-items:center;gap:8px}
.card-head h2 svg{color:var(--text-dim)}
.card-sub{font-size:12px;color:var(--text-faint);margin-top:1px}
.btn{display:inline-flex;align-items:center;gap:6px;padding:8px 14px;border-radius:var(--radius-sm);font-size:13px;font-weight:500;border:1px solid var(--border);background:var(--surface-2);color:var(--text);cursor:pointer;transition:.15s ease;white-space:nowrap;font-family:inherit}
.btn svg{width:15px;height:15px;flex:none}
.btn:hover{border-color:#324063;background:#1c2740;transform:translateY(-1px)}
.btn:active{transform:translateY(0)}
.btn:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.btn:disabled{opacity:.4;cursor:not-allowed;transform:none!important}
.btn-sm{padding:6px 10px;font-size:12px}
.btn-sm svg{width:14px;height:14px}
.btn-accent{background:var(--accent);border-color:var(--accent);color:#fff}
.btn-accent:hover{background:#4a7bef;border-color:#4a7bef}
.btn-success{color:var(--success);border-color:rgba(47,216,166,.35);background:var(--success-soft)}
.btn-success:hover{background:var(--success);color:#04231a;border-color:var(--success)}
.btn-warning{color:var(--warning);border-color:rgba(242,184,75,.35);background:var(--warning-soft)}
.btn-warning:hover{background:var(--warning);color:#2a1c02;border-color:var(--warning)}
.btn-danger{color:var(--danger);border-color:rgba(244,88,110,.35);background:var(--danger-soft)}
.btn-danger:hover{background:var(--danger);color:#2a0810;border-color:var(--danger)}
.btn-ghost{background:transparent}
.toolbar{display:flex;flex-wrap:wrap;gap:8px;padding:16px 20px}
.badge{display:inline-flex;align-items:center;gap:5px;padding:3px 10px;border-radius:999px;font-size:11.5px;font-weight:600;letter-spacing:.01em;white-space:nowrap}
.badge svg{width:11px;height:11px}
.badge-active{background:var(--success-soft);color:var(--success)}
.badge-inactive{background:var(--danger-soft);color:var(--danger)}
.badge-authenticated{background:var(--success-soft);color:var(--success)}
.badge-unauthenticated{background:var(--danger-soft);color:var(--danger)}
.badge-info{background:var(--info-soft);color:var(--info)}
.instance-header{display:flex;align-items:center;justify-content:space-between;padding:16px 20px;border-bottom:1px solid var(--border-soft)}
.instance-name{font-size:15px;font-weight:650;display:flex;align-items:center;gap:10px}
.detail-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:14px;padding:16px 20px}
.detail-item{font-size:12.5px}
.detail-label{color:var(--text-faint);font-weight:500;margin-bottom:3px;font-size:11px;text-transform:uppercase;letter-spacing:.03em}
.detail-value{color:var(--text);font-weight:600;font-variant-numeric:tabular-nums}
.detail-value.mono{font-family:var(--mono);font-size:12px;font-weight:500}
.detail-value.active{color:var(--success)}
.detail-value.inactive{color:var(--danger)}
.status-inline{display:inline-flex;align-items:center;gap:4px}
.status-inline svg{width:12px;height:12px;flex:none}
.subpanel{margin:0 20px 16px;padding:12px 14px;background:var(--surface-2);border:1px solid var(--border-soft);border-radius:var(--radius-sm);font-size:12.5px;border-left:3px solid var(--border)}
.subpanel.ok{border-left-color:var(--success)}
.subpanel.bad{border-left-color:var(--danger)}
.subpanel-title{font-weight:600;display:flex;align-items:center;gap:8px;margin-bottom:2px;flex-wrap:wrap}
.subpanel-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:8px;margin-top:8px}
.domain-check{margin:0 20px 16px;padding:12px 14px;background:var(--surface-2);border:1px solid var(--border-soft);border-radius:var(--radius-sm);font-size:12.5px;border-left:3px solid var(--border)}
.logs-toggle{display:flex;align-items:center;gap:6px;width:calc(100% - 40px);margin:0 20px 16px;padding:8px 12px;background:var(--surface-2);border:1px solid var(--border);border-radius:var(--radius-sm);color:var(--text-dim);font-size:12.5px;cursor:pointer;transition:.15s ease}
.logs-toggle:hover{color:var(--text);border-color:#324063}
.logs-toggle svg:last-child{transition:transform .2s ease;margin-left:auto}
.logs-toggle.open svg:last-child{transform:rotate(180deg)}
.logs-section{display:none;margin:0 20px 16px;padding:12px;background:#080b12;border:1px solid var(--border);border-radius:var(--radius-sm)}
.logs-section.show{display:block}
.logs-container{max-height:420px;overflow-y:auto;font-family:var(--mono);font-size:11.5px;color:#c3cadb;line-height:1.5}
.log-line{padding:2px 6px;word-break:break-all;border-radius:4px}
.log-error{background:rgba(244,88,110,.12);color:#ff8fa0}
.log-success{background:rgba(47,216,166,.12);color:#7ee8c8}
.actions{display:flex;gap:8px;flex-wrap:wrap;padding:16px 20px;border-top:1px solid var(--border-soft)}
.actions .danger-group{margin-left:auto;display:flex;gap:8px;padding-left:12px;border-left:1px solid var(--border-soft)}
.stat-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:14px;padding:16px 20px}
.stat{font-size:12.5px}
.stat-label{color:var(--text-faint);font-size:11px;text-transform:uppercase;letter-spacing:.03em;margin-bottom:5px}
.stat-value{font-weight:650;font-size:14px;font-variant-numeric:tabular-nums;margin-bottom:6px}
.meter{height:4px;border-radius:2px;background:var(--border-soft);overflow:hidden}
.meter-fill{height:100%;border-radius:2px;background:var(--success);transition:width .4s ease}
.meter-fill.warn{background:var(--warning)}
.meter-fill.crit{background:var(--danger)}
.scripts-row{display:flex;flex-wrap:wrap;gap:8px;font-size:12px;color:var(--text-dim);padding:0 20px 16px}
.script-chip{display:inline-flex;align-items:center;gap:5px;padding:3px 9px;border-radius:999px;background:var(--surface-2);border:1px solid var(--border-soft)}
.script-chip svg{width:11px;height:11px}
.script-chip.ok svg{color:var(--success)}
.script-chip.missing svg{color:var(--danger)}
.maintenance-status{font-size:12px;color:var(--text-dim);padding:0 20px 12px}
.maintenance-output{display:none;margin:0 20px 18px;background:#080b12;border-radius:var(--radius-sm);border:1px solid var(--border);padding:12px;max-height:360px;overflow:auto}
.maintenance-output pre{color:#c3cadb;font-family:var(--mono);font-size:11.5px;line-height:1.5;white-space:pre-wrap;word-break:break-word}
.loading{display:flex;flex-direction:column;align-items:center;gap:10px;padding:48px;color:var(--text-dim);font-size:13px}
.spinner{width:26px;height:26px;border-radius:50%;border:2.5px solid var(--border);border-top-color:var(--accent);animation:spin .8s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
#toasts{position:fixed;top:16px;right:16px;z-index:1000;display:flex;flex-direction:column;gap:8px;max-width:360px}
.toast{display:flex;align-items:flex-start;gap:10px;padding:12px 14px;border-radius:var(--radius-sm);background:var(--surface);border:1px solid var(--border);box-shadow:var(--shadow);font-size:13px;animation:toast-in .18s ease}
@keyframes toast-in{from{opacity:0;transform:translateY(-6px)}to{opacity:1;transform:translateY(0)}}
.toast svg{flex:none;margin-top:1px;width:16px;height:16px}
.toast.info svg{color:var(--info)}
.toast.success svg{color:var(--success)}
.toast.error svg{color:var(--danger)}
.toast-msg{flex:1;line-height:1.4}
.toast-close{cursor:pointer;color:var(--text-faint);flex:none;background:none;border:none;padding:0;font-size:15px;line-height:1}
.toast-close:hover{color:var(--text)}
dialog.reset-admin-dialog{border:none;border-radius:var(--radius);padding:22px;max-width:440px;width:90%;position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);margin:0;background:var(--surface);color:var(--text);box-shadow:var(--shadow);border:1px solid var(--border)}
dialog.reset-admin-dialog::backdrop{background:rgba(4,6,12,.65);backdrop-filter:blur(2px)}
.reset-field-label{display:block;font-size:12.5px;margin-bottom:5px;color:var(--text-dim)}
.reset-input{width:100%;padding:9px 10px;margin-bottom:12px;border:1px solid var(--border);border-radius:var(--radius-sm);background:var(--surface-2);color:var(--text);font-size:13px;font-family:inherit}
.reset-input:focus{outline:2px solid var(--accent);outline-offset:1px}
.reset-checkbox-label{display:flex;align-items:center;gap:8px;margin-bottom:12px;font-size:12.5px;color:var(--text-dim)}
.reset-dialog-actions{display:flex;gap:10px;justify-content:flex-end;margin-top:6px}
.reset-section{border-top:1px solid var(--border-soft);border-bottom:1px solid var(--border-soft);padding:14px 0;margin-bottom:14px}
.reset-preview{font-size:12px;color:var(--text-dim);margin-top:6px;word-break:break-all;font-family:var(--mono)}
.toolbar-danger{margin-left:auto}
.kpi-row{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:14px;padding:16px 20px}
.kpi{font-size:12.5px}
.kpi-label{color:var(--text-faint);font-size:11px;text-transform:uppercase;letter-spacing:.03em;margin-bottom:5px}
.kpi-value{font-weight:700;font-size:22px;font-variant-numeric:tabular-nums}
.kpi-value.success{color:var(--success)}
.kpi-value.danger{color:var(--danger)}
#instances{display:grid;grid-template-columns:repeat(auto-fill,minmax(420px,1fr));gap:16px}
.field{font-size:12.5px}
.field-label{color:var(--text-faint);font-size:11px;text-transform:uppercase;letter-spacing:.03em;margin-bottom:5px;display:block}
.field select,.field input,.field textarea{width:100%;padding:8px 10px;border:1px solid var(--border);border-radius:var(--radius-sm);background:var(--surface-2);color:var(--text);font-size:13px;font-family:inherit}
.field select:focus,.field input:focus,.field textarea:focus{outline:2px solid var(--accent);outline-offset:1px}
.field textarea{min-height:70px;resize:vertical;font-family:var(--mono);font-size:12px}
.terminal-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px;padding:16px 20px 0}
.terminal-run{padding:0 20px;margin-top:12px}
.terminal-output{margin:12px 20px 18px;background:#080b12;border-radius:var(--radius-sm);border:1px solid var(--border);padding:12px;max-height:360px;overflow:auto}
.terminal-output pre{color:#c3cadb;font-family:var(--mono);font-size:11.5px;line-height:1.5;white-space:pre-wrap;word-break:break-word}
@media (max-width:640px){
.detail-grid,.stat-grid,.subpanel-grid,.kpi-row{grid-template-columns:repeat(2,1fr)}
.actions .danger-group{margin-left:0;padding-left:0;border-left:none;width:100%;border-top:1px dashed var(--border-soft);padding-top:8px;margin-top:2px}
.toolbar-danger{margin-left:0;width:100%;border-top:1px dashed var(--border-soft);padding-top:8px;margin-top:2px}
.live span.live-text{display:none}
#instances{grid-template-columns:1fr}
}
@media (prefers-reduced-motion:reduce){
*{animation-duration:.001ms!important;transition-duration:.001ms!important}
}
"""

class RestartHandler(http.server.BaseHTTPRequestHandler):
    JOBS = {}
    JOBS_LOCK = Lock()
    JOB_LIMIT = 50
    GIT_FETCH_CACHE = {}
    GIT_LOCK = Lock()
    GIT_FETCH_TTL = 300

    def _now_iso(self):
        return datetime.now().isoformat(sep=' ', timespec='seconds')

    def _strip_ansi(self, text):
        if not text:
            return text
        ansi_re = re.compile(r"\x1B\[[0-?]*[ -/]*[@-~]")
        return ansi_re.sub("", text)

    def _truncate_output(self, text, limit=20000):
        if text is None:
            return ""
        if len(text) <= limit:
            return text
        return text[:limit] + "\n...\n(Output truncated)"

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

    def _git_run(self, instance_dir, args, timeout=6):
        try:
            result = subprocess.run(
                ["git"] + args,
                cwd=instance_dir,
                capture_output=True,
                text=True,
                timeout=timeout
            )
            if result.returncode != 0:
                return None
            return result.stdout.strip()
        except Exception:
            return None

    def _ensure_git_safe(self, instance_dir):
        try:
            subprocess.run(
                ["sudo", "git", "config", "--global", "--add", "safe.directory", instance_dir],
                capture_output=True,
                text=True,
                timeout=4
            )
        except Exception:
            pass

    def _get_default_branch(self, instance_dir):
        ref = self._git_run(instance_dir, ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"])
        if ref and ref.startswith("refs/remotes/origin/"):
            return ref.split("/", 3)[-1]
        if self._git_run(instance_dir, ["show-ref", "--verify", "--quiet", "refs/remotes/origin/main"]) is not None:
            return "main"
        if self._git_run(instance_dir, ["show-ref", "--verify", "--quiet", "refs/remotes/origin/master"]) is not None:
            return "master"
        return "main"

    def _maybe_fetch_origin(self, instance_dir):
        with self.GIT_LOCK:
            cached = self.GIT_FETCH_CACHE.get(instance_dir, {})
            last_ts = cached.get("ts", 0)
            if time.time() - last_ts < self.GIT_FETCH_TTL:
                return
            self.GIT_FETCH_CACHE[instance_dir] = {"ts": time.time()}
        try:
            subprocess.run(
                ["sudo", "git", "fetch", "--prune", "origin"],
                cwd=instance_dir,
                capture_output=True,
                text=True,
                timeout=15
            )
        except Exception:
            pass

    def _get_git_info(self, instance):
        instance_dir = f"/var/python/openalgo-flask/{instance}"
        if not os.path.isdir(os.path.join(instance_dir, ".git")):
            return None

        self._ensure_git_safe(instance_dir)
        self._maybe_fetch_origin(instance_dir)

        branch = self._get_default_branch(instance_dir)
        current_commit = self._git_run(instance_dir, ["rev-parse", "--short", "HEAD"])
        latest_commit = self._git_run(instance_dir, ["rev-parse", "--short", f"origin/{branch}"])
        current_date = self._git_run(instance_dir, ["log", "-1", "--format=%cd", "--date=iso", "HEAD"])
        latest_date = self._git_run(instance_dir, ["log", "-1", "--format=%cd", "--date=iso", f"origin/{branch}"])
        ahead_behind = self._git_run(instance_dir, ["rev-list", "--left-right", "--count", f"HEAD...origin/{branch}"])
        ahead = behind = None
        if ahead_behind and " " in ahead_behind:
            ahead_str, behind_str = ahead_behind.split(" ", 1)
            try:
                ahead = int(ahead_str)
                behind = int(behind_str)
            except Exception:
                ahead = behind = None

        return {
            "branch": branch,
            "current_commit": current_commit,
            "current_date": current_date,
            "latest_commit": latest_commit,
            "latest_date": latest_date,
            "ahead": ahead,
            "behind": behind,
        }

    def _list_db_files(self, instance):
        inst_path = f"/var/python/openalgo-flask/{instance}"
        db_dir = f"{inst_path}/db"
        files = []
        if os.path.isdir(db_dir):
            for entry in os.scandir(db_dir):
                if entry.is_file() and entry.name.endswith(".db"):
                    files.append(entry.name)
        return sorted(files)

    def _is_safe_select(self, query):
        if not query:
            return False
        if len(query) > 1000:
            return False
        q = query.strip()
        if not q.lower().startswith("select"):
            return False
        if ";" in q.rstrip(";"):
            return False
        lowered = q.lower()
        if re.search(r"\b(insert|update|delete|drop|alter|create|pragma|attach|detach|vacuum|reindex)\b", lowered):
            return False
        return True

    def _list_instances(self):
        base_dir = "/var/python/openalgo-flask"
        instances = []
        if os.path.isdir(base_dir):
            for entry in os.scandir(base_dir):
                if not entry.is_dir(follow_symlinks=False):
                    continue
                if not entry.name.startswith("openalgo"):
                    continue
                suffix = entry.name[8:]
                if suffix.isdigit() or (suffix.startswith("-") and suffix[1:] and all(ch.isalnum() or ch == "-" for ch in suffix[1:])):
                    instances.append(entry.name)
        return sorted(instances)

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
        """Invalidate session using instance auth models and reset master contract status."""
        inst_path = f"/var/python/openalgo-flask/{instance}"
        result = {
            "instance": instance,
            "auth_updated": False,
            "auth_error": None,
            "output": "",
            "exit_code": None,
        }

        if not os.path.isdir(inst_path):
            result["auth_error"] = "Instance not found"
            return result
        script_path = self._find_script("oa-invalidate-session.sh")
        if not script_path:
            result["auth_error"] = "oa-invalidate-session.sh not found"
            return result

        try:
            proc = subprocess.run(
                ["sudo", "bash", script_path, "--instance", instance],
                cwd=inst_path,
                capture_output=True,
                text=True,
                timeout=60,
            )
            result["exit_code"] = proc.returncode
            result["output"] = (proc.stdout or "") + (("\n" + proc.stderr) if proc.stderr else "")
            if proc.returncode == 0:
                result["auth_updated"] = True
            else:
                result["auth_error"] = f"Script failed (exit {proc.returncode})"
        except Exception as e:
            result["auth_error"] = str(e)

        return result

    def _reset_admin_user(self, instance, broker_creds=None):
        """Delete all rows from the users and auth tables via oa-reset-admin.sh,
        forcing the instance back into first-time admin setup and requiring a
        fresh broker login. Use when a user forgot their password and has no
        TOTP/QR reset or working SMTP configured.

        broker_creds, if given, is a dict that may contain broker (the new
        broker short name, used to update REDIRECT_URL), broker_api_key,
        broker_api_secret, broker_api_key_market, broker_api_secret_market —
        these are also written into the instance's .env file."""
        inst_path = f"/var/python/openalgo-flask/{instance}"
        result = {
            "instance": instance,
            "reset": False,
            "error": None,
            "output": "",
            "exit_code": None,
        }

        if not os.path.isdir(inst_path):
            result["error"] = "Instance not found"
            return result
        script_path = self._find_script("oa-reset-admin.sh")
        if not script_path:
            result["error"] = "oa-reset-admin.sh not found"
            return result

        command = ["sudo", "bash", script_path, "--instance", instance, "--force"]
        cred_flags = {
            "broker": "--broker",
            "broker_api_key": "--broker-api-key",
            "broker_api_secret": "--broker-api-secret",
            "broker_api_key_market": "--broker-api-key-market",
            "broker_api_secret_market": "--broker-api-secret-market",
        }
        for key, flag in cred_flags.items():
            value = (broker_creds or {}).get(key, "")
            if isinstance(value, str) and value.strip():
                command.extend([flag, value.strip()])

        try:
            proc = subprocess.run(
                command,
                cwd=inst_path,
                capture_output=True,
                text=True,
                timeout=60,
            )
            result["exit_code"] = proc.returncode
            result["output"] = (proc.stdout or "") + (("\n" + proc.stderr) if proc.stderr else "")
            if proc.returncode == 0:
                result["reset"] = True
            else:
                result["error"] = f"Script failed (exit {proc.returncode})"
        except Exception as e:
            result["error"] = str(e)

        return result

    def _read_auth_status(self, instance):
        db_file = self._get_auth_db_file(instance)
        if not db_file:
            return False, "User Not Setup", None, None
        try:
            conn = sqlite3.connect(db_file)
            cur = conn.cursor()
            cur.execute("SELECT is_revoked, broker, name FROM auth LIMIT 1")
            row = cur.fetchone()
            conn.close()
            if not row:
                return False, "User Not Setup", None, None
            is_revoked, broker, name = row
            if is_revoked in (1, "1", True):
                return False, "User Not Authenticated: Token Revoked", broker, name
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
                    m = re.match(r"^DOMAIN\s*=\s*(.+)", line)
                    if m:
                        domain = m.group(1).strip().strip("'\"")
                        break
        if domain:
            return f"openalgo-{domain.replace('.', '-')}"
        return instance

    def _sanitize_instance(self, instance):
        if not instance:
            return None
        instance = instance.strip()
        import re
        if re.match(r"^openalgo\d+$", instance):
            return instance
        if re.match(r"^openalgo-[A-Za-z0-9-]+$", instance):
            return instance
        if re.match(r"^[A-Za-z0-9.-]+$", instance):
            candidate = f"openalgo-{instance.replace('.', '-')}"
            if os.path.isdir(f"/var/python/openalgo-flask/{candidate}"):
                return candidate
        return None

    def _resolve_instance_from_host(self):
        host = self.headers.get("Host", "")
        host = host.split(":", 1)[0].strip()
        if not host:
            return None
        import re
        if not re.match(r"^[A-Za-z0-9.-]+$", host):
            return None
        candidate = f"/var/python/openalgo-flask/openalgo-{host.replace('.', '-')}"
        if os.path.exists(candidate):
            return self._sanitize_instance(os.path.basename(candidate))
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
        elif self.path.startswith('/api/terminal/dbs'):
            self.handle_terminal_dbs()
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
        elif path == '/monitor/api/reset-admin-user':
            instance = self._require_monitor_instance()
            if instance:
                self.handle_reset_admin_user(instance, data)
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
        elif path == '/api/reset-admin-user':
            instance = data.get('instance', '')
            if instance:
                self.handle_reset_admin_user(instance, data)
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
        elif self.path == '/api/terminal/run':
            self.handle_terminal_run(data)
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
                        if suffix.isdigit() or (suffix.startswith("-") and suffix[1:] and all(ch.isalnum() or ch == "-" for ch in suffix[1:])):
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
                        if suffix.isdigit() or (suffix.startswith("-") and suffix[1:] and all(ch.isalnum() or ch == "-" for ch in suffix[1:])):
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
                        if suffix.isdigit() or (suffix.startswith("-") and suffix[1:] and all(ch.isalnum() or ch == "-" for ch in suffix[1:])):
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
            clear_script = self._find_script("oa-clear-logs.sh")
            if not clear_script:
                self.send_json({"error": "oa-clear-logs.sh not found", "instance": instance}, 500)
                return

            proc = subprocess.run(
                ["sudo", "bash", clear_script, "--yes", "--instance", instance],
                capture_output=True,
                text=True,
                timeout=600,
            )
            message = (proc.stdout or "").strip()
            if proc.returncode != 0:
                self.send_json({
                    "instance": instance,
                    "error": f"Clear logs failed (exit {proc.returncode})",
                    "output": message,
                    "timestamp": str(datetime.now())
                }, 500)
                return

            self.send_json({
                "instance": instance,
                "message": "Clear logs completed",
                "output": message,
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
        script_names = ["oa-health-check.sh", "oa-update.sh", "oa-backup.sh", "oa-clear-logs.sh", "oa-invalidate-session.sh", "oa-reset-admin.sh"]
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

    def handle_terminal_dbs(self):
        params = parse_qs(urlparse(self.path).query)
        instance = self._sanitize_instance(params.get("instance", [None])[0])
        if not instance:
            instances = self._list_instances()
            instance = instances[0] if instances else None
        if not instance:
            self.send_json({"error": "Invalid or missing instance"}, 400)
            return
        dbs = self._list_db_files(instance)
        self.send_json({"instance": instance, "dbs": dbs, "timestamp": self._now_iso()})

    def handle_terminal_run(self, data):
        action = (data.get("action") or "").strip()
        instance = self._sanitize_instance(data.get("instance"))
        lines = data.get("lines", 100)
        db_name = data.get("db")
        query = data.get("query")

        allowed = {"systemctl_status", "journalctl_tail", "df", "free", "uptime", "sqlite_select"}
        if action not in allowed:
            self.send_json({"error": "Action not allowed"}, 400)
            return

        try:
            lines = int(lines)
        except Exception:
            lines = 100
        if lines < 10:
            lines = 10
        if lines > 500:
            lines = 500

        cmd = None
        if action in ("systemctl_status", "journalctl_tail"):
            if not instance:
                instances = self._list_instances()
                instance = instances[0] if instances else None
            if not instance:
                self.send_json({"error": "Instance required for this action"}, 400)
                return
            service_name = self._service_name(instance)
            if action == "systemctl_status":
                cmd = ["systemctl", "status", service_name, "--no-pager"]
            else:
                cmd = ["journalctl", "-u", service_name, "-n", str(lines), "--no-pager"]
        elif action == "df":
            cmd = ["df", "-h"]
        elif action == "free":
            cmd = ["free", "-h"]
        elif action == "uptime":
            cmd = ["uptime"]
        elif action == "sqlite_select":
            if not instance:
                instances = self._list_instances()
                instance = instances[0] if instances else None
            if not instance:
                self.send_json({"error": "Instance required for sqlite query"}, 400)
                return
            if not query or not self._is_safe_select(query):
                self.send_json({"error": "Only single SELECT statements are allowed"}, 400)
                return
            if not db_name or not str(db_name).endswith(".db"):
                self.send_json({"error": "DB name required"}, 400)
                return
            dbs = self._list_db_files(instance)
            if db_name not in dbs:
                self.send_json({"error": "DB not allowed"}, 400)
                return
            db_path = f"/var/python/openalgo-flask/{instance}/db/{db_name}"
            if not shutil.which("sqlite3"):
                self.send_json({"error": "sqlite3 not installed"}, 400)
                return
            cmd = ["sqlite3", db_path, "-header", "-column", query]

        if not cmd:
            self.send_json({"error": "Command not available"}, 400)
            return

        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=15
            )
            output = (result.stdout or "") + ("\n" + result.stderr if result.stderr else "")
            output = self._strip_ansi(output)
            output = self._truncate_output(output)
            self.send_json({
                "status": "success" if result.returncode == 0 else "error",
                "exit_code": result.returncode,
                "output": output.strip(),
                "timestamp": self._now_iso()
            })
        except subprocess.TimeoutExpired:
            self.send_json({"error": "Command timed out"}, 504)
        except Exception as e:
            self.send_json({"error": str(e)}, 500)

    def _check_domain_http(self, domain):
        """Check if the main app domain responds over HTTPS."""
        import urllib.request
        import ssl
        url = f"https://{domain}/"
        try:
            ctx = ssl.create_default_context()
            req = urllib.request.Request(url, headers={"User-Agent": "OpenAlgo-Monitor/1.0"})
            with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
                return {"reachable": True, "status_code": resp.status, "url": url}
        except urllib.error.HTTPError as e:
            return {"reachable": True, "status_code": e.code, "url": url}
        except Exception as e:
            return {"reachable": False, "status_code": None, "error": str(e)[:120], "url": url}

    def _get_instance_health(self, instance):
        """Get detailed health info for a single instance"""
        health = {"name": instance, "status": "unknown", "port": None, "database": False, "broker": None, "domain": None, "env_version": None, "auth_name": None, "auth_status": None, "session_valid": True, "master_contract": None, "git": None, "valid_brokers": []}

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
                        m = re.match(r"^DOMAIN\s*=\s*(.+)", line)
                        if m:
                            health["domain"] = m.group(1).strip().strip("'\"")
                            continue
                        m = re.match(r"^FLASK_PORT\s*=\s*(.+)", line)
                        if m:
                            health["port"] = m.group(1).strip().strip("'\"")
                            continue
                        m = re.match(r"^ENV_CONFIG_VERSION\s*=\s*(.+)", line)
                        if m:
                            health["env_version"] = m.group(1).strip().strip("'\"")
                            continue
                        m = re.match(r"^VALID_BROKERS\s*=\s*(.+)", line)
                        if m:
                            raw = m.group(1).strip().strip("'\"")
                            health["valid_brokers"] = [b.strip() for b in raw.split(",") if b.strip()]
                            continue
                        if 'REDIRECT_URL' in line and '=' in line:
                            redirect_url = line.split('=', 1)[1].strip().strip("'\"")
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

        if health.get("domain"):
            try:
                health["domain_check"] = self._check_domain_http(health["domain"])
            except Exception:
                health["domain_check"] = {"reachable": False, "error": "check failed", "url": ""}

        try:
            health["git"] = self._get_git_info(instance)
        except Exception:
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
        Thread(
            target=self._restart_instance_background,
            args=(instance, service_name),
            daemon=True,
        ).start()

        self.send_json({
            "status": "success",
            "message": f"Restart queued for {instance}",
            "instance": instance,
            "service": service_name,
            "timestamp": str(datetime.now())
        })

    def _clear_instance_logs_quick(self, instance):
        """Delete per-instance log files without running full system cleanup."""
        inst_path = f"/var/python/openalgo-flask/{instance}"
        deleted = 0

        for log_dir_name in ("log", "logs"):
            log_dir = os.path.join(inst_path, log_dir_name)
            if not os.path.isdir(log_dir):
                continue

            for root, dirs, files in os.walk(log_dir, topdown=False):
                for filename in files:
                    file_path = os.path.join(root, filename)
                    try:
                        os.remove(file_path)
                        deleted += 1
                    except FileNotFoundError:
                        continue
                    except Exception:
                        continue

                for dirname in dirs:
                    dir_path = os.path.join(root, dirname)
                    try:
                        os.rmdir(dir_path)
                    except OSError:
                        continue

        return deleted

    def _restart_instance_background(self, instance, service_name):
        """Run restart-related work without blocking the monitor HTTP server."""
        try:
            self._invalidate_session(instance)
        except Exception:
            pass

        try:
            self._clear_instance_logs_quick(instance)
        except Exception:
            pass

        try:
            subprocess.run(
                ["sudo", "systemctl", "restart", service_name],
                capture_output=True,
                text=True,
                timeout=60,
            )
        except Exception:
            pass

        try:
            subprocess.run(
                ["sudo", "systemctl", "reload", "nginx"],
                capture_output=True,
                text=True,
                timeout=30,
            )
        except Exception:
            pass

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

    def handle_reset_admin_user(self, instance, data=None):
        """Delete all users for a specific instance, forcing first-time setup.
        Optionally also switches the active broker (data['broker'], which
        updates REDIRECT_URL) and/or rotates broker API credentials in .env
        when data includes broker_api_key / broker_api_secret / *_market
        fields."""
        broker_creds = {
            "broker": (data or {}).get("broker", ""),
            "broker_api_key": (data or {}).get("broker_api_key", ""),
            "broker_api_secret": (data or {}).get("broker_api_secret", ""),
            "broker_api_key_market": (data or {}).get("broker_api_key_market", ""),
            "broker_api_secret_market": (data or {}).get("broker_api_secret_market", ""),
        }
        result = self._reset_admin_user(instance, broker_creds)
        self.send_json({
            "status": "success" if result.get("reset") else "error",
            "message": f"Factory reset complete for {instance}" if result.get("reset") else (result.get("error") or "Reset failed"),
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
        server_ip = get_server_ip()
        manager_url = f"http://{server_ip}:{PORT}/" if server_ip else "/"
        html = ("""<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenAlgo Monitor</title>
<style>""" + DASHBOARD_CSS + """</style>
</head>
<body>
<div class="topbar">
<div class="brand">
<div class="brand-mark"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12h4l3 8 4-16 3 8h4"/></svg></div>
<div class="brand-text"><b>OpenAlgo</b><span>Instance Monitor</span></div>
</div>
<div class="topbar-right">
<span class="live"><span class="dot pulse"></span><span class="live-text" id="last-updated">Loading…</span></span>
<a class="icon-btn" href="__MANAGER_URL__" title="All Instances"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/></svg></a>
<button class="icon-btn" title="Refresh" onclick="loadInstance()"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M23 4v6h-6M1 20v-6h6"/><path d="M3.51 9a9 9 0 0114.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0020.49 15"/></svg></button>
</div>
</div>
<main>
<div id="toasts" role="status" aria-live="polite"></div>

<div class="card">
<div class="toolbar">
<button class="btn btn-accent" onclick="loadInstance()">Refresh</button>
<button class="btn" onclick="restartInstance()">Restart Instance</button>
<button class="btn btn-warning" onclick="rebootServer()">Reboot Server</button>
<button class="btn" onclick="clearLogs()">Clear Logs</button>
<button class="btn" onclick="invalidateSession()">Invalidate Session</button>
<div class="toolbar-danger"><button class="btn btn-danger" onclick="resetAdminUser()">Factory Reset</button></div>
</div>
</div>

<div id="system" class="card"></div>

<div class="card">
<div class="card-head"><h2>Maintenance</h2></div>
<div id="scripts-status" class="scripts-row"></div>
<div class="toolbar" style="padding-top:0">
<button id="btn-health-instance" class="btn" onclick="runHealthCheck()">Health Check</button>
<button id="btn-update-instance" class="btn" onclick="updateInstance()">Update Instance</button>
</div>
<div id="maintenance-status" class="maintenance-status"></div>
<div id="maintenance-output" class="maintenance-output"><pre id="maintenance-output-pre"></pre></div>
</div>

<div id="loading" class="loading"><div class="spinner"></div><p>Loading instance...</p></div>
<div id="instance"></div>
</main>

<dialog id="resetAdminDialog" class="reset-admin-dialog">
<form method="dialog" id="resetAdminForm">
<h3 style="margin:0 0 10px;color:var(--danger);display:flex;align-items:center;gap:8px;font-size:16px"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/><path d="M12 9v4M12 17h.01"/></svg>Factory Reset</h3>
<p style="font-size:13px;color:var(--text-dim);margin:0 0 15px;line-height:1.5">Deletes all users and clears the broker login session for this instance. The next visit will require first-time admin setup and a fresh broker login. Use only when there's no TOTP/QR reset and no working SMTP.</p>
<div class="reset-section">
<label class="reset-field-label">Broker</label>
<select id="resetBroker" class="reset-input" onchange="updateCallbackPreview()">
<option value="">Keep current broker</option>
</select>
<div id="resetCallbackPreview" class="reset-preview"></div>
</div>
<label class="reset-checkbox-label"><input type="checkbox" id="resetRotateCreds" onchange="document.getElementById('resetCredsFields').style.display=this.checked?'block':'none'"> Also update broker API key/secret in .env</label>
<div id="resetCredsFields" style="display:none">
<label class="reset-field-label">New BROKER_API_KEY</label>
<input type="text" id="resetApiKey" class="reset-input" placeholder="Leave blank to keep existing">
<label class="reset-field-label">New BROKER_API_SECRET</label>
<input type="password" id="resetApiSecret" class="reset-input" placeholder="Leave blank to keep existing">
<label class="reset-checkbox-label"><input type="checkbox" id="resetXts" onchange="document.getElementById('resetXtsFields').style.display=this.checked?'block':'none'"> This broker also needs separate market-data credentials (XTS-based)</label>
<div id="resetXtsFields" style="display:none">
<label class="reset-field-label">New BROKER_API_KEY_MARKET</label>
<input type="text" id="resetApiKeyMarket" class="reset-input" placeholder="Leave blank to keep existing">
<label class="reset-field-label">New BROKER_API_SECRET_MARKET</label>
<input type="password" id="resetApiSecretMarket" class="reset-input" placeholder="Leave blank to keep existing">
</div>
</div>
<div class="reset-dialog-actions">
<button type="button" class="btn btn-ghost" onclick="document.getElementById('resetAdminDialog').close()">Cancel</button>
<button type="submit" value="confirm" class="btn btn-danger">Factory Reset</button>
</div>
</form>
</dialog>

<script>
const ICON_CHECK='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><path d="M20 6L9 17l-5-5"/></svg>';
const ICON_X='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><path d="M18 6L6 18M6 6l12 12"/></svg>';
const TOAST_ICONS={
info:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/></svg>',
success:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M9 12l2 2 4-4"/></svg>',
error:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/><path d="M12 9v4M12 17h.01"/></svg>'
};
const ICON_LOGS='<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6h16M4 12h16M4 18h10"/></svg>';
const ICON_CHEVRON='<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6"/></svg>';
const monitorInstance="__INSTANCE__";
let resolvedInstance=null;
let logsLoaded=false;
const monitorApiBase='/monitor/api';
async function fetchJson(url, options){
const opts=options||{};
const headers=new Headers(opts.headers||{});
if(url.startsWith(monitorApiBase)){
const inst=resolvedInstance||monitorInstance;
if(inst){headers.set('X-OpenAlgo-Instance',inst);}
}
opts.headers=headers;
const r=await fetch(url,opts);
const text=await r.text();
const contentType=(r.headers.get('content-type')||'').toLowerCase();
try{
return JSON.parse(text);
}catch(e){
const preview=text.replace(/\\s+/g,' ').slice(0,160);
throw new Error(`Invalid JSON from ${url} (status ${r.status}, type ${contentType||'unknown'}): ${preview}`);
}
}
let lastHealth=null;
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
lastHealth=h;
renderSystem(h.system);
renderScriptsStatus(scriptsStatus);
renderInstance(h);
const lu=document.getElementById('last-updated');
if(lu){lu.textContent='Live · updated '+new Date().toLocaleTimeString();}
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
return `<span class="script-chip ${ok?'ok':'missing'}">${ok?ICON_CHECK:ICON_X} ${name}</span>`;
}).join('');
let extra='';
if(data.missing&&data.missing.length){
const fix=data.suggested_fix||'sudo ln -sf /path/to/openalgo-scripts/*.sh /usr/local/bin/';
extra=`<div style="margin-top:6px;width:100%"><strong>Fix:</strong> <code>${escapeHtml(fix)}</code></div>`;
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
const git=h.git||{};
const gitCurrent=git.current_commit||'N/A';
const gitLatest=git.latest_commit||'N/A';
const gitBehind=(git.behind!==null&&git.behind!==undefined)?`${git.behind} behind`:'';
const gitUpdated=git.current_date||'Unknown';
const gitSummary=gitCurrent===gitLatest?`${gitCurrent} (up to date)`:`${gitCurrent} → ${gitLatest} ${gitBehind}`.trim();
const dc=h.domain_check||{};
const dcOk=dc.reachable===true&&dc.status_code>=200&&dc.status_code<400;
const dcClass=dcOk?'ok':(dc.reachable?'':'bad');
const dcBadge=dcOk?`<span class="badge badge-authenticated">${ICON_CHECK} ${dc.status_code} OK</span>`:`<span class="badge badge-unauthenticated">${ICON_X} ${dc.reachable?dc.status_code:'Unreachable'}</span>`;
const dcExtra=dc.error?`<div style="color:var(--danger);font-size:11px;margin-top:3px">${escapeHtml(dc.error)}</div>`:'';
const dcHtml=domain!=='Unknown'&&h.domain_check!==undefined?`<div class="domain-check ${dcClass}"><strong>App Reachability</strong> | <a href="https://${domain}" target="_blank" rel="noopener">${domain}</a> | ${dcBadge}${dcExtra}</div>`:'';
const actions=active
?`<button class="btn btn-sm btn-danger" onclick="stopInstance()">Stop</button>`
:`<button class="btn btn-sm btn-success" onclick="startInstance()">Start</button>`;
document.getElementById('instance').innerHTML=`<div class="card"><div class="instance-header"><div class="instance-name">${inst}<span class="badge ${active?'badge-active':'badge-inactive'}">${active?ICON_CHECK+' Active':ICON_X+' Inactive'}</span></div></div><div class="detail-grid"><div class="detail-item"><div class="detail-label">Domain</div><div class="detail-value">${domain!=='Unknown'?`<a href="https://${domain}" target="_blank" rel="noopener">${domain} ↗</a>`:domain}</div></div><div class="detail-item"><div class="detail-label">Env Version</div><div class="detail-value">${h.env_version||'—'}</div></div><div class="detail-item"><div class="detail-label">Status</div><div class="detail-value ${active?'active':'inactive'}">${h.status||'unknown'}</div></div><div class="detail-item"><div class="detail-label">Flask Port</div><div class="detail-value">${h.port||'N/A'}</div></div><div class="detail-item"><div class="detail-label">Database</div><div class="detail-value status-inline">${h.database?ICON_CHECK+' Present':ICON_X+' Missing'}</div></div><div class="detail-item"><div class="detail-label">Git</div><div class="detail-value mono">${gitSummary}</div></div><div class="detail-item"><div class="detail-label">Code Updated</div><div class="detail-value">${gitUpdated}</div></div></div>${dcHtml}<div class="subpanel ${isAuthenticated?'ok':'bad'}"><div class="subpanel-title">${authName} | Broker: ${broker} ${brokerAuthBadge}</div></div><div class="subpanel ${mcReady?'ok':'bad'}"><div class="subpanel-title">Master Contract Data ${mcBadge}</div><div class="subpanel-grid"><div><div class="detail-label">Last Updated</div><div class="detail-value">${mcLast}</div></div><div><div class="detail-label">Total Symbols</div><div class="detail-value">${mcSymbols}</div></div><div><div class="detail-label">Broker</div><div class="detail-value">${mcBroker}</div></div><div><div class="detail-label">Message</div><div class="detail-value">${mcMessage}</div></div></div></div><button class="logs-toggle" onclick="toggleLogs()">${ICON_LOGS}View Logs${ICON_CHEVRON}</button><div id="logs" class="logs-section"><div class="logs-container" id="logs-content"><p style="color:var(--text-faint)">Loading logs...</p></div></div><div class="actions"><button class="btn btn-sm" onclick="restartInstance()">Restart</button><div class="danger-group">${actions}</div></div></div>`;
}
function toggleLogs(){
const logsSection=document.getElementById('logs');
if(!logsSection)return;
logsSection.classList.toggle('show');
document.querySelector('.logs-toggle')?.classList.toggle('open');
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
logsContent.innerHTML='<p style="color:var(--text-faint)">No logs available</p>';
}
}catch(e){
document.getElementById('logs-content').innerHTML=`<p style="color:var(--danger)">Error loading logs: ${e.message}</p>`;
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
function meterClass(p){
if(p===null||p===undefined)return '';
if(p>=90)return 'crit';
if(p>=70)return 'warn';
return '';
}
function meter(p){
if(p===null||p===undefined)return '';
return `<div class="meter"><div class="meter-fill ${meterClass(p)}" style="width:${Math.min(p,100)}%"></div></div>`;
}
function renderSystem(sys){
const el=document.getElementById('system');
if(!sys){
el.innerHTML='<div class="card-head"><h2>System</h2></div><p style="color:var(--text-faint);padding:0 20px 16px">System stats unavailable</p>';
return;
}
el.innerHTML=`<div class="card-head"><h2>System</h2></div>
<div class="stat-grid">
<div class="stat"><div class="stat-label">CPU</div><div class="stat-value">${formatPercent(sys.cpu_percent)}</div>${meter(sys.cpu_percent)}</div>
<div class="stat"><div class="stat-label">Load Avg</div><div class="stat-value">${sys.load1??'N/A'} / ${sys.load5??'N/A'} / ${sys.load15??'N/A'}</div></div>
<div class="stat"><div class="stat-label">RAM Used</div><div class="stat-value">${formatBytes(sys.mem_used)} / ${formatBytes(sys.mem_total)} (${formatPercent(sys.mem_percent)})</div>${meter(sys.mem_percent)}</div>
<div class="stat"><div class="stat-label">Swap Used</div><div class="stat-value">${formatBytes(sys.swap_used)} / ${formatBytes(sys.swap_total)} (${formatPercent(sys.swap_percent)})</div>${meter(sys.swap_percent)}</div>
<div class="stat"><div class="stat-label">Storage Used</div><div class="stat-value">${formatBytes(sys.disk_used)} / ${formatBytes(sys.disk_total)} (${formatPercent(sys.disk_percent)})</div>${meter(sys.disk_percent)}</div>
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
try{
const res=await post('/monitor/api/clear-logs');
if(res&&res.error){
showAlert(res.error,'error');
return;
}
const msg=res&&res.message?res.message:'Logs cleared';
showAlert(msg,'success');
}catch(e){
showAlert('Error: '+e.message,'error');
return;
}
logsLoaded=false;
setTimeout(loadInstance,1000);
}
async function invalidateSession(){
if(!confirm('Invalidate the session for this instance? This will clear auth tokens and revoke the session.'))return;
showAlert('Invalidating session...','info');
await post('/monitor/api/invalidate-session');
setTimeout(loadInstance,1000);
}
let resetDialogHealth=null;
function populateBrokerSelect(){
const sel=document.getElementById('resetBroker');
const h=resetDialogHealth||{};
const current=h.broker||'';
sel.innerHTML='';
const keepOpt=document.createElement('option');
keepOpt.value='';
keepOpt.textContent=current?`Keep current broker (${current})`:'Keep current broker';
sel.appendChild(keepOpt);
(h.valid_brokers||[]).forEach(b=>{
const opt=document.createElement('option');
opt.value=b;
opt.textContent=b;
sel.appendChild(opt);
});
updateCallbackPreview();
}
function updateCallbackPreview(){
const h=resetDialogHealth||{};
const sel=document.getElementById('resetBroker');
const chosen=(sel&&sel.value)||h.broker||'';
const preview=document.getElementById('resetCallbackPreview');
if(preview)preview.textContent=(h.domain&&chosen)?`Callback URL: https://${h.domain}/${chosen}/callback`:'';
}
function openResetAdminDialog(health){
resetDialogHealth=health||{};
const dlg=document.getElementById('resetAdminDialog');
document.getElementById('resetAdminForm').reset();
populateBrokerSelect();
document.getElementById('resetCredsFields').style.display='none';
document.getElementById('resetXtsFields').style.display='none';
return new Promise(resolve=>{
dlg.returnValue='';
dlg.showModal();
dlg.onclose=function(){
if(dlg.returnValue!=='confirm'){resolve(null);return;}
const broker=document.getElementById('resetBroker').value;
if(!document.getElementById('resetRotateCreds').checked){resolve(broker?{broker:broker}:{});return;}
const xts=document.getElementById('resetXts').checked;
resolve({
broker:broker,
broker_api_key:document.getElementById('resetApiKey').value.trim(),
broker_api_secret:document.getElementById('resetApiSecret').value.trim(),
broker_api_key_market:xts?document.getElementById('resetApiKeyMarket').value.trim():'',
broker_api_secret_market:xts?document.getElementById('resetApiSecretMarket').value.trim():''
});
};
});
}
async function resetAdminUser(){
const creds=await openResetAdminDialog(lastHealth);
if(creds===null)return;
showAlert('Resetting admin user...','info');
try{
const res=await fetchJson('/monitor/api/reset-admin-user',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(creds)});
const msg=res&&res.message?res.message:'Factory reset complete';
showAlert(msg,res&&res.status==='error'?'error':'success');
}catch(e){
showAlert('Error: '+e.message,'error');
return;
}
setTimeout(loadInstance,1000);
}
async function rebootServer(){
if(!confirm('Reboot the server? This will reboot all instances on this server.'))return;
if(!confirm('FINAL CONFIRMATION: The server will restart now. Continue?'))return;
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
const list=document.getElementById('toasts');
if(!list)return;
const t=document.createElement('div');
t.className=`toast ${type}`;
t.innerHTML=`${TOAST_ICONS[type]||TOAST_ICONS.info}<div class="toast-msg"></div><button class="toast-close" aria-label="Dismiss" onclick="this.parentElement.remove()">×</button>`;
t.querySelector('.toast-msg').textContent=msg;
list.appendChild(t);
if(type!=='error')setTimeout(()=>t.remove(),4000);
}
window.addEventListener('load',loadInstance);
setInterval(loadInstance,30000);
</script>
</body>
</html>""")

        html = html.replace("__INSTANCE__", instance).replace("__MANAGER_URL__", manager_url)
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
        html = ("""<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenAlgo Manager</title>
<style>""" + DASHBOARD_CSS + """</style>
</head>
<body>
<div class="topbar">
<div class="brand">
<div class="brand-mark"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12h4l3 8 4-16 3 8h4"/></svg></div>
<div class="brand-text"><b>OpenAlgo</b><span>Instance Manager</span></div>
</div>
<div class="topbar-right">
<span class="live"><span class="dot pulse"></span><span class="live-text" id="last-updated">Loading…</span></span>
<button class="icon-btn" title="Refresh" onclick="loadInstances()"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M23 4v6h-6M1 20v-6h6"/><path d="M3.51 9a9 9 0 0114.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0020.49 15"/></svg></button>
</div>
</div>
<main>
<div id="toasts" role="status" aria-live="polite"></div>

<div class="card">
<div class="card-head"><h2>Summary</h2></div>
<div id="summary" class="kpi-row"><div class="kpi"><div class="kpi-label">Instances</div><div class="kpi-value">Loading…</div></div></div>
</div>

<div id="system" class="card"></div>

<div class="card">
<div class="card-head"><h2>Maintenance</h2></div>
<div id="scripts-status" class="scripts-row"></div>
<div class="toolbar" style="padding-top:0">
<button id="btn-health-all" class="btn" onclick="runHealthCheck('all')">Health Check (All)</button>
<button id="btn-health-system" class="btn" onclick="runHealthCheck('system')">Health Check (System)</button>
<button id="btn-update-all" class="btn" onclick="updateAll()">Update All Instances</button>
</div>
<div id="maintenance-status" class="maintenance-status"></div>
<div id="maintenance-output" class="maintenance-output"><pre id="maintenance-output-pre"></pre></div>
</div>

<div class="card">
<div class="card-head"><h2>Terminal <span class="card-sub" style="margin-left:6px;font-weight:400">(safe, read-only commands)</span></h2></div>
<div class="terminal-grid">
<div class="field">
<span class="field-label">Action</span>
<select id="term-action">
<option value="systemctl_status">Systemctl Status</option>
<option value="journalctl_tail">Journalctl Tail</option>
<option value="df">Disk Usage (df -h)</option>
<option value="free">Memory (free -h)</option>
<option value="uptime">Uptime</option>
<option value="sqlite_select">sqlite3 SELECT</option>
</select>
</div>
<div id="term-instance-wrap" class="field">
<span class="field-label">Instance</span>
<select id="term-instance"></select>
</div>
<div id="term-lines-wrap" class="field">
<span class="field-label">Lines</span>
<input id="term-lines" type="number" min="10" max="500" value="100"/>
</div>
<div id="term-db-wrap" class="field">
<span class="field-label">DB</span>
<select id="term-db"></select>
</div>
</div>
<div id="term-query-wrap" class="field" style="padding:0 20px;margin-top:12px">
<span class="field-label">Query (SELECT only)</span>
<textarea id="term-query"></textarea>
</div>
<div class="terminal-run"><button class="btn btn-accent" onclick="runTerminal()">Run Command</button></div>
<div class="terminal-output"><pre id="term-output">Ready.</pre></div>
</div>

<div class="card">
<div class="toolbar">
<button class="btn" onclick="restartAll()">Restart All Instances</button>
<button class="btn btn-accent" onclick="loadInstances()">Refresh</button>
<button class="btn btn-warning" onclick="rebootServer()">Reboot Server</button>
</div>
</div>

<div id="loading" class="loading"><div class="spinner"></div><p>Loading instances...</p></div>
<div id="instances"></div>
</main>

<dialog id="resetAdminDialog" class="reset-admin-dialog">
<form method="dialog" id="resetAdminForm">
<h3 style="margin:0 0 10px;color:var(--danger);display:flex;align-items:center;gap:8px;font-size:16px"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/><path d="M12 9v4M12 17h.01"/></svg>Factory Reset<span id="resetAdminInstanceLabel"></span></h3>
<p style="font-size:13px;color:var(--text-dim);margin:0 0 15px;line-height:1.5">Deletes all users and clears the broker login session. The next visit will require first-time admin setup and a fresh broker login. Use only when there's no TOTP/QR reset and no working SMTP.</p>
<div class="reset-section">
<label class="reset-field-label">Broker</label>
<select id="resetBroker" class="reset-input" onchange="updateCallbackPreview()">
<option value="">Keep current broker</option>
</select>
<div id="resetCallbackPreview" class="reset-preview"></div>
</div>
<label class="reset-checkbox-label"><input type="checkbox" id="resetRotateCreds" onchange="document.getElementById('resetCredsFields').style.display=this.checked?'block':'none'"> Also update broker API key/secret in .env</label>
<div id="resetCredsFields" style="display:none">
<label class="reset-field-label">New BROKER_API_KEY</label>
<input type="text" id="resetApiKey" class="reset-input" placeholder="Leave blank to keep existing">
<label class="reset-field-label">New BROKER_API_SECRET</label>
<input type="password" id="resetApiSecret" class="reset-input" placeholder="Leave blank to keep existing">
<label class="reset-checkbox-label"><input type="checkbox" id="resetXts" onchange="document.getElementById('resetXtsFields').style.display=this.checked?'block':'none'"> This broker also needs separate market-data credentials (XTS-based)</label>
<div id="resetXtsFields" style="display:none">
<label class="reset-field-label">New BROKER_API_KEY_MARKET</label>
<input type="text" id="resetApiKeyMarket" class="reset-input" placeholder="Leave blank to keep existing">
<label class="reset-field-label">New BROKER_API_SECRET_MARKET</label>
<input type="password" id="resetApiSecretMarket" class="reset-input" placeholder="Leave blank to keep existing">
</div>
</div>
<div class="reset-dialog-actions">
<button type="button" class="btn btn-ghost" onclick="document.getElementById('resetAdminDialog').close()">Cancel</button>
<button type="submit" value="confirm" class="btn btn-danger">Factory Reset</button>
</div>
</form>
</dialog>

<script>
const ICON_CHECK='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><path d="M20 6L9 17l-5-5"/></svg>';
const ICON_X='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><path d="M18 6L6 18M6 6l12 12"/></svg>';
const TOAST_ICONS={
info:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/></svg>',
success:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M9 12l2 2 4-4"/></svg>',
error:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/><path d="M12 9v4M12 17h.01"/></svg>'
};
const ICON_LOGS='<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6h16M4 12h16M4 18h10"/></svg>';
const ICON_CHEVRON='<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6"/></svg>';
let brokerStatusCache={};
let logsCache={};
let terminalInstances=[];
let terminalInitialized=false;
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
let lastHealthAll={};
async function loadInstances(){
try{
document.getElementById('loading').style.display='block';
const [instances, scriptsStatus, health]=await Promise.all([
fetchJson('/api/instances'),
fetchJson('/api/scripts-status'),
fetchJson('/api/health')
]);
document.getElementById('loading').style.display='none';
if(!instances||instances.length===0){
document.getElementById('instances').innerHTML='<p style="color:var(--text-faint)">No instances found</p>';
return;
}
lastHealthAll=health.instances||{};
renderScriptsStatus(scriptsStatus);
renderInstances(instances, health, true);
const lu=document.getElementById('last-updated');
if(lu){lu.textContent='Live · updated '+new Date().toLocaleTimeString();}
}catch(e){
showAlert('Error: '+e.message,'error');
}
}
function renderInstances(instances, health, initTerminal){
const running=Object.values(health.instances||{}).filter(i=>i.status==='active').length;
document.getElementById('summary').innerHTML=`<div class="kpi"><div class="kpi-label">Total Instances</div><div class="kpi-value">${instances.length}</div></div><div class="kpi"><div class="kpi-label">Running</div><div class="kpi-value success">${running}</div></div><div class="kpi"><div class="kpi-label">Stopped</div><div class="kpi-value danger">${instances.length-running}</div></div>`;
renderSystem(health.system);
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
const git=h.git||{};
const gitCurrent=git.current_commit||'N/A';
const gitLatest=git.latest_commit||'N/A';
const gitBehind=(git.behind!==null&&git.behind!==undefined)?`${git.behind} behind`:'';
const gitUpdated=git.current_date||'Unknown';
const gitSummary=gitCurrent===gitLatest?`${gitCurrent} (up to date)`:`${gitCurrent} → ${gitLatest} ${gitBehind}`.trim();
const actions=active
?`<button class="btn btn-sm btn-danger" onclick="stop('${inst}')">Stop</button>`
:`<button class="btn btn-sm btn-success" onclick="start('${inst}')">Start</button>`;
const monitorHref=domain!=='Unknown'?`https://${domain}/monitor`:`/monitor?instance=${inst}`;
return`<div class="card"><div class="instance-header"><div class="instance-name">${inst}<span class="badge ${active?'badge-active':'badge-inactive'}">${active?ICON_CHECK+' Active':ICON_X+' Inactive'}</span></div><a class="icon-btn" href="${monitorHref}" target="_blank" rel="noopener" title="Open monitor page for ${inst}"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 13v6a2 2 0 01-2 2H5a2 2 0 01-2-2V8a2 2 0 012-2h6"/><path d="M15 3h6v6"/><path d="M10 14L21 3"/></svg></a></div><div class="detail-grid"><div class="detail-item"><div class="detail-label">Domain</div><div class="detail-value">${domain!=='Unknown'?`<a href="https://${domain}" target="_blank" rel="noopener">${domain} ↗</a>`:domain}</div></div><div class="detail-item"><div class="detail-label">Env Version</div><div class="detail-value">${h.env_version||'—'}</div></div><div class="detail-item"><div class="detail-label">Status</div><div class="detail-value ${active?'active':'inactive'}">${h.status||'unknown'}</div></div><div class="detail-item"><div class="detail-label">Flask Port</div><div class="detail-value">${h.port||'N/A'}</div></div><div class="detail-item"><div class="detail-label">Database</div><div class="detail-value status-inline">${h.database?ICON_CHECK+' Present':ICON_X+' Missing'}</div></div><div class="detail-item"><div class="detail-label">Git</div><div class="detail-value mono">${gitSummary}</div></div><div class="detail-item"><div class="detail-label">Code Updated</div><div class="detail-value">${gitUpdated}</div></div></div><div class="subpanel ${isAuthenticated?'ok':'bad'}"><div class="subpanel-title">${authName} | Broker: ${broker} ${brokerAuthBadge}</div></div><div class="subpanel ${mcReady?'ok':'bad'}"><div class="subpanel-title">Master Contract Data ${mcBadge}</div><div class="subpanel-grid"><div><div class="detail-label">Last Updated</div><div class="detail-value">${mcLast}</div></div><div><div class="detail-label">Total Symbols</div><div class="detail-value">${mcSymbols}</div></div><div><div class="detail-label">Broker</div><div class="detail-value">${mcBroker}</div></div><div><div class="detail-label">Message</div><div class="detail-value">${mcMessage}</div></div></div></div><button class="logs-toggle" onclick="toggleLogs('${inst}')">${ICON_LOGS}View Logs${ICON_CHEVRON}</button><div id="logs-${inst}" class="logs-section"><div class="logs-container" id="logs-content-${inst}"><p style="color:var(--text-faint)">Loading logs...</p></div></div><div class="actions"><button class="btn btn-sm" onclick="runHealthCheck('instance','${inst}')">Health</button><button class="btn btn-sm" onclick="updateInstance('${inst}')">Update</button><button class="btn btn-sm" onclick="restart('${inst}')">Restart</button><div class="danger-group"><button class="btn btn-sm" onclick="invalidate('${inst}')">Invalidate</button><button class="btn btn-sm btn-danger" onclick="resetAdminUser('${inst}')">Factory Reset</button>${actions}</div></div></div>`;
}).join('');
document.getElementById('instances').innerHTML=html;
if(initTerminal && !terminalInitialized){
populateTerminalInstances(instances);
terminalInitialized=true;
}
}
function populateTerminalInstances(instances){
const select=document.getElementById('term-instance');
if(!select)return;
terminalInstances=Array.isArray(instances)?instances:[];
if(!instances||instances.length===0){
select.innerHTML='<option value="">No instances</option>';
}else{
select.innerHTML=instances.map(i=>`<option value="${i}">${i}</option>`).join('');
}
if(select.options.length){
select.selectedIndex=0;
}
updateTerminalFields();
}
function getSelectedInstance(){
const select=document.getElementById('term-instance');
if(!select)return'';
let val='';
if(select.selectedOptions&&select.selectedOptions.length){
const opt=select.selectedOptions[0];
val=(opt.value||opt.text||'').trim();
}
if(!val){
val=(select.value||'').trim();
}
if(!val&&select.options&&select.options.length){
const opt=select.options[0];
val=(opt.value||opt.text||'').trim();
}
return val;
}
function resolveInstance(){
let inst=getSelectedInstance();
const select=document.getElementById('term-instance');
if(!inst&&select&&select.options&&select.options.length){
select.selectedIndex=0;
inst=getSelectedInstance();
}
if(!inst&&terminalInstances.length){
inst=terminalInstances[0];
if(select){select.value=inst;}
}
return (inst||'').trim();
}
function updateTerminalFields(){
const action=document.getElementById('term-action')?.value;
const dbWrap=document.getElementById('term-db-wrap');
const queryWrap=document.getElementById('term-query-wrap');
const linesWrap=document.getElementById('term-lines-wrap');
const instanceWrap=document.getElementById('term-instance-wrap');
if(dbWrap){dbWrap.style.display=(action==='sqlite_select')?'block':'none';}
if(queryWrap){queryWrap.style.display=(action==='sqlite_select')?'block':'none';}
if(linesWrap){linesWrap.style.display=(action==='journalctl_tail')?'block':'none';}
if(instanceWrap){instanceWrap.style.display=(action==='df'||action==='free'||action==='uptime')?'none':'block';}
loadTerminalDbs();
}
async function loadTerminalDbs(){
const action=document.getElementById('term-action')?.value;
const inst=resolveInstance();
const dbSelect=document.getElementById('term-db');
if(!dbSelect)return;
if(!inst){
dbSelect.innerHTML='<option value="">Select instance</option>';
return;
}
if(action!=='sqlite_select'){
dbSelect.innerHTML='';
return;
}
try{
const data=await fetchJson(`/api/terminal/dbs?instance=${encodeURIComponent(inst)}`);
const dbs=data.dbs||[];
dbSelect.innerHTML=dbs.length?dbs.map(d=>`<option value="${d}">${d}</option>`).join(''):'<option value="">No databases found</option>';
}catch(e){
dbSelect.innerHTML='<option value="">Error loading dbs</option>';
}
}
document.getElementById('term-action')?.addEventListener('change',()=>{
updateTerminalFields();
});
document.getElementById('term-instance')?.addEventListener('change',loadTerminalDbs);
document.getElementById('term-action')?.dispatchEvent(new Event('change'));

async function runTerminal(){
const action=document.getElementById('term-action').value;
const instance=resolveInstance();
const lines=document.getElementById('term-lines').value;
const db=document.getElementById('term-db').value;
const query=document.getElementById('term-query').value;
const output=document.getElementById('term-output');
if(output){output.textContent='Running...';}
if((action==='systemctl_status'||action==='journalctl_tail'||action==='sqlite_select')&&!instance){
if(output){output.textContent='Instance required for this action.';}
return;
}
if(action==='sqlite_select' && !db){
if(output){output.textContent='Please select a database.';}
return;
}
if(action==='sqlite_select' && (!query||!query.trim())){
if(output){output.textContent='Please enter a SELECT query.';}
return;
}
const payload={action,instance,lines,db,query};
try{
const data=await fetchJson('/api/terminal/run',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});
if(data.error){
if(output){output.textContent=data.error;}
return;
}
if(output){output.textContent=data.output||'';}
}catch(e){
if(output){output.textContent=e.message;}
}
}
function renderScriptsStatus(data){
const el=document.getElementById('scripts-status');
if(!el||!data||!data.scripts){
return;
}
const items=Object.entries(data.scripts).map(([name,info])=>{
const ok=info&&info.found;
return `<span class="script-chip ${ok?'ok':'missing'}">${ok?ICON_CHECK:ICON_X} ${name}</span>`;
}).join('');
let extra='';
if(data.missing&&data.missing.length){
const fix=data.suggested_fix||'sudo ln -sf /path/to/openalgo-scripts/*.sh /usr/local/bin/';
extra=`<div style="margin-top:6px;width:100%"><strong>Fix:</strong> <code>${escapeHtml(fix)}</code></div>`;
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
event?.currentTarget?.classList.toggle('open');
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
logsContent.innerHTML='<p style="color:var(--text-faint)">No logs available</p>';
}
}catch(e){
document.getElementById(`logs-content-${inst}`).innerHTML=`<p style="color:var(--danger)">Error loading logs: ${e.message}</p>`;
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
function meterClass(p){
if(p===null||p===undefined)return '';
if(p>=90)return 'crit';
if(p>=70)return 'warn';
return '';
}
function meter(p){
if(p===null||p===undefined)return '';
return `<div class="meter"><div class="meter-fill ${meterClass(p)}" style="width:${Math.min(p,100)}%"></div></div>`;
}
function renderSystem(sys){
const el=document.getElementById('system');
if(!sys){
el.innerHTML='<div class="card-head"><h2>System</h2></div><p style="color:var(--text-faint);padding:0 20px 16px">System stats unavailable</p>';
return;
}
el.innerHTML=`<div class="card-head"><h2>System</h2></div>
<div class="stat-grid">
<div class="stat"><div class="stat-label">CPU</div><div class="stat-value">${formatPercent(sys.cpu_percent)}</div>${meter(sys.cpu_percent)}</div>
<div class="stat"><div class="stat-label">Load Avg</div><div class="stat-value">${sys.load1??'N/A'} / ${sys.load5??'N/A'} / ${sys.load15??'N/A'}</div></div>
<div class="stat"><div class="stat-label">RAM Used</div><div class="stat-value">${formatBytes(sys.mem_used)} / ${formatBytes(sys.mem_total)} (${formatPercent(sys.mem_percent)})</div>${meter(sys.mem_percent)}</div>
<div class="stat"><div class="stat-label">Swap Used</div><div class="stat-value">${formatBytes(sys.swap_used)} / ${formatBytes(sys.swap_total)} (${formatPercent(sys.swap_percent)})</div>${meter(sys.swap_percent)}</div>
<div class="stat"><div class="stat-label">Storage Used</div><div class="stat-value">${formatBytes(sys.disk_used)} / ${formatBytes(sys.disk_total)} (${formatPercent(sys.disk_percent)})</div>${meter(sys.disk_percent)}</div>
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
let resetDialogHealth=null;
function populateBrokerSelect(){
const sel=document.getElementById('resetBroker');
const h=resetDialogHealth||{};
const current=h.broker||'';
sel.innerHTML='';
const keepOpt=document.createElement('option');
keepOpt.value='';
keepOpt.textContent=current?`Keep current broker (${current})`:'Keep current broker';
sel.appendChild(keepOpt);
(h.valid_brokers||[]).forEach(b=>{
const opt=document.createElement('option');
opt.value=b;
opt.textContent=b;
sel.appendChild(opt);
});
updateCallbackPreview();
}
function updateCallbackPreview(){
const h=resetDialogHealth||{};
const sel=document.getElementById('resetBroker');
const chosen=(sel&&sel.value)||h.broker||'';
const preview=document.getElementById('resetCallbackPreview');
if(preview)preview.textContent=(h.domain&&chosen)?`Callback URL: https://${h.domain}/${chosen}/callback`:'';
}
function openResetAdminDialog(inst){
resetDialogHealth=(lastHealthAll&&lastHealthAll[inst])||{};
const dlg=document.getElementById('resetAdminDialog');
document.getElementById('resetAdminForm').reset();
populateBrokerSelect();
document.getElementById('resetCredsFields').style.display='none';
document.getElementById('resetXtsFields').style.display='none';
document.getElementById('resetAdminInstanceLabel').textContent=inst?` for ${inst}`:'';
return new Promise(resolve=>{
dlg.returnValue='';
dlg.showModal();
dlg.onclose=function(){
if(dlg.returnValue!=='confirm'){resolve(null);return;}
const broker=document.getElementById('resetBroker').value;
if(!document.getElementById('resetRotateCreds').checked){resolve(broker?{broker:broker}:{});return;}
const xts=document.getElementById('resetXts').checked;
resolve({
broker:broker,
broker_api_key:document.getElementById('resetApiKey').value.trim(),
broker_api_secret:document.getElementById('resetApiSecret').value.trim(),
broker_api_key_market:xts?document.getElementById('resetApiKeyMarket').value.trim():'',
broker_api_secret_market:xts?document.getElementById('resetApiSecretMarket').value.trim():''
});
};
});
}
async function resetAdminUser(inst){
const creds=await openResetAdminDialog(inst);
if(creds===null)return;
showAlert(`Resetting admin user for ${inst}...`,'info');
try{
const res=await fetchJson('/api/reset-admin-user',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(Object.assign({instance:inst},creds))});
showAlert(res&&res.message?res.message:`Factory reset complete for ${inst}`,res&&res.status==='error'?'error':'success');
}catch(e){
showAlert('Error: '+e.message,'error');
return;
}
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
if(!confirm('Are you sure you want to reboot the server? This will disconnect all instances!'))return;
if(!confirm('FINAL CONFIRMATION: The server will restart now. Continue?'))return;
showAlert('Rebooting server... Connection will be lost shortly.','info');
try{
const d=await fetchJson('/api/reboot-server',{method:'POST'});
showAlert(d.message,'success');
}catch(e){
showAlert('Reboot initiated (API connection lost as expected)','success');
}
}
function showAlert(msg,type){
const list=document.getElementById('toasts');
if(!list)return;
const t=document.createElement('div');
t.className=`toast ${type}`;
t.innerHTML=`${TOAST_ICONS[type]||TOAST_ICONS.info}<div class="toast-msg"></div><button class="toast-close" aria-label="Dismiss" onclick="this.parentElement.remove()">×</button>`;
t.querySelector('.toast-msg').textContent=msg;
list.appendChild(t);
if(type!=='error')setTimeout(()=>t.remove(),4000);
}
window.addEventListener('load',loadInstances);
setInterval(loadInstances,30000);
</script>
</body>
</html>""")
        
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

    class ReusableTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
        allow_reuse_address = True
        daemon_threads = True

    server = ReusableTCPServer(("0.0.0.0", PORT), RestartHandler)
    
    print(f"OpenAlgo API running on 0.0.0.0:{PORT}", flush=True)
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Server stopped", flush=True)
    except Exception as e:
        print(f"Error: {e}", flush=True)
        sys.exit(1)
