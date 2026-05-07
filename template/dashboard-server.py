#!/usr/bin/env python3
"""
__PROJECT_NAME__ dashboard server.

Serves the repo root statically AND exposes a tiny JSON API so the dashboard
can read/write progress/tasks.json. Claude reads/writes the same file on disk
— so tasks flow in both directions.

Run:   python3 dashboard-server.py
Then:  open http://localhost:8765/dashboard.html
"""

import json
import os
import sys
from datetime import datetime, timezone
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = 8765
ROOT = Path(__file__).resolve().parent
TASKS_FILE = ROOT / "progress" / "tasks.json"


def read_tasks() -> dict:
    if not TASKS_FILE.exists():
        return {"version": 1, "updatedAt": _now(), "tasks": []}
    try:
        with TASKS_FILE.open("r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, list):
            # Legacy shape — wrap it
            data = {"version": 1, "updatedAt": _now(), "tasks": data}
        data.setdefault("version", 1)
        data.setdefault("tasks", [])
        return data
    except (json.JSONDecodeError, OSError) as e:
        print(f"[warn] couldn't read tasks.json: {e}", file=sys.stderr)
        return {"version": 1, "updatedAt": _now(), "tasks": []}


def write_tasks(data: dict) -> None:
    TASKS_FILE.parent.mkdir(parents=True, exist_ok=True)
    data["updatedAt"] = _now()
    tmp = TASKS_FILE.with_suffix(".json.tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    tmp.replace(TASKS_FILE)


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def log_message(self, fmt, *args):
        # Keep the console quiet for asset fetches
        if any(part in self.path for part in ("/api/", "dashboard.html")):
            super().log_message(fmt, *args)

    # ---- CORS / caching ---------------------------------------------------
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    # ---- API routing ------------------------------------------------------
    def do_GET(self):
        if self.path.startswith("/api/tasks"):
            return self._send_json(200, read_tasks())
        return super().do_GET()

    def do_POST(self):
        if self.path == "/api/tasks":
            return self._write_full()
        if self.path == "/api/tasks/add":
            return self._add_task()
        return self._send_json(404, {"error": "unknown endpoint"})

    def do_PUT(self):
        if self.path.startswith("/api/tasks/"):
            return self._update_task(self.path.split("/")[-1])
        return self._send_json(404, {"error": "unknown endpoint"})

    def do_DELETE(self):
        if self.path.startswith("/api/tasks/"):
            return self._delete_task(self.path.split("/")[-1])
        return self._send_json(404, {"error": "unknown endpoint"})

    # ---- Handlers ---------------------------------------------------------
    def _write_full(self):
        """Replace the entire tasks payload."""
        payload = self._read_body()
        if payload is None:
            return
        data = read_tasks()
        if isinstance(payload, list):
            data["tasks"] = payload
        elif isinstance(payload, dict) and isinstance(payload.get("tasks"), list):
            data["tasks"] = payload["tasks"]
        else:
            return self._send_json(400, {"error": "body must be {tasks:[]} or an array"})
        write_tasks(data)
        self._send_json(200, data)

    def _add_task(self):
        payload = self._read_body()
        if payload is None:
            return
        data = read_tasks()
        new = {
            "id": payload.get("id") or _uid(),
            "text": (payload.get("text") or "").strip(),
            "status": payload.get("status") or "active",
            "notes": payload.get("notes") or "",
            "createdAt": _now(),
            "updatedAt": _now(),
            "lastTouchedBy": payload.get("lastTouchedBy") or "user",
            "claudeStatus": payload.get("claudeStatus") or "idle",
        }
        if not new["text"]:
            return self._send_json(400, {"error": "text required"})
        data["tasks"].append(new)
        write_tasks(data)
        self._send_json(200, {"task": new, "tasks": data["tasks"]})

    def _update_task(self, task_id: str):
        payload = self._read_body()
        if payload is None:
            return
        data = read_tasks()
        task = next((t for t in data["tasks"] if t.get("id") == task_id), None)
        if not task:
            return self._send_json(404, {"error": "not found"})
        for key in ("text", "status", "notes", "claudeStatus", "lastTouchedBy"):
            if key in payload:
                task[key] = payload[key]
        task["updatedAt"] = _now()
        write_tasks(data)
        self._send_json(200, {"task": task})

    def _delete_task(self, task_id: str):
        data = read_tasks()
        before = len(data["tasks"])
        data["tasks"] = [t for t in data["tasks"] if t.get("id") != task_id]
        if len(data["tasks"]) == before:
            return self._send_json(404, {"error": "not found"})
        write_tasks(data)
        self._send_json(200, {"ok": True, "tasks": data["tasks"]})

    # ---- utils ------------------------------------------------------------
    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return {}
        try:
            return json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            self._send_json(400, {"error": "invalid JSON"})
            return None

    def _send_json(self, status: int, body: dict):
        payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def _uid() -> str:
    import secrets
    return secrets.token_hex(8)


def main():
    os.chdir(ROOT)
    with ThreadingHTTPServer(("127.0.0.1", PORT), Handler) as srv:
        print(f"__PROJECT_NAME__ dashboard serving {ROOT} at http://localhost:{PORT}/dashboard.html")
        print(f"Tasks file: {TASKS_FILE}")
        print("Ctrl+C to stop.")
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            print("\nBye.")


if __name__ == "__main__":
    main()
