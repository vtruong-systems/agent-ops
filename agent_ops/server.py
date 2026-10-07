"""HTTP wrapper around run_turn. GET /healthz and POST /turns."""

from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import yaml

from agent_ops.spec import AgentNotFoundError, SpecError, load_agents
from agent_ops.turn import run_turn


class TurnHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802
        if self.path.split("?", 1)[0] != "/healthz":
            self._json(404, {"error": "not_found"})
            return
        try:
            agents = load_agents()
        except (SpecError, yaml.YAMLError, OSError, TypeError, ValueError):
            self._json(503, {"status": "unhealthy", "error": "bad_spec"})
            return
        if not agents:
            self._json(503, {"status": "unhealthy", "error": "bad_spec"})
            return
        self._json(200, {"status": "ok", "agents": len(agents)})

    def do_POST(self) -> None:  # noqa: N802
        if self.path.split("?", 1)[0] != "/turns":
            self._json(404, {"error": "not_found"})
            return
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b""
        try:
            data = json.loads(raw.decode("utf-8") or "{}")
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._json(400, {"error": "malformed"})
            return
        if not isinstance(data, dict) or not isinstance(data.get("agent"), str) or not isinstance(data.get("input"), str):
            self._json(400, {"error": "malformed"})
            return
        case_id = data.get("case_id")
        if case_id is not None and not isinstance(case_id, str):
            self._json(400, {"error": "malformed"})
            return
        try:
            result = run_turn(data["agent"], data["input"], case_id)
        except AgentNotFoundError:
            self._json(404, {"error": "unknown_agent"})
            return
        self._json(200, result)

    def log_message(self, fmt: str, *args) -> None:
        return

    def _json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def serve(host: str = "0.0.0.0", port: int = 8080) -> ThreadingHTTPServer:
    return ThreadingHTTPServer((host, port), TurnHandler)


def main() -> None:
    port = int(os.environ.get("AGENT_OPS_PORT", "8080"))
    server = serve("0.0.0.0", port)
    print(f"listening on {port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
