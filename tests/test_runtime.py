import json
import threading
import urllib.error
import urllib.request
from pathlib import Path

import pytest

from agent_ops.eval import main
from agent_ops.server import serve
from agent_ops.turn import run_turn


def test_hello_turn():
    result = run_turn("hello", "hi", "hello-hi")
    assert result["output"] == "hello"
    assert result["error"] is None
    assert result["agent_version"] == 0


def test_fixture_eval(tmp_path: Path):
    report = tmp_path / "eval-report.json"
    code = main(["--provider", "fake", "--report", str(report)])
    assert code == 0
    payload = json.loads(report.read_text(encoding="utf-8"))
    assert payload["results"][0]["id"] == "hello-hi"
    assert payload["results"][0]["pass"] is True


def test_draft_failure_does_not_fail(tmp_path: Path, monkeypatch):
    agent = tmp_path / "agents" / "hello"
    agent.mkdir(parents=True)
    (agent / "agent.yaml").write_text(
        "name: hello\nversion: 0\nprovider: fake\nfake_output: hello\ntools: []\n",
        encoding="utf-8",
    )
    cases = tmp_path / "evals" / "cases" / "hello"
    cases.mkdir(parents=True)
    (cases / "draft.yaml").write_text(
        "id: draft-nope\nagent: hello\nstatus: draft\ninput: hi\nscorers:\n  - name: exact\n    value: nope\n",
        encoding="utf-8",
    )
    monkeypatch.setenv("AGENT_OPS_ROOT", str(tmp_path))
    code = main(["--provider", "fake", "--suite", "evals/cases", "--report", str(tmp_path / "report.json")])
    assert code == 0


def test_http_turn():
    server = serve("127.0.0.1", 0)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        body = json.dumps({"agent": "hello", "input": "hi", "case_id": "hello-hi"}).encode()
        request = urllib.request.Request(
            f"http://127.0.0.1:{port}/turns",
            data=body,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            payload = json.load(response)
            assert response.status == 200
        assert payload["output"] == "hello"
    finally:
        server.shutdown()


def test_health_requires_loadable_agent_specs(tmp_path: Path, monkeypatch):
    agents = tmp_path / "agents" / "broken"
    agents.mkdir(parents=True)
    (agents / "agent.yaml").write_text("name: wrong\nprovider: fake\n", encoding="utf-8")
    monkeypatch.setenv("AGENT_OPS_ROOT", str(tmp_path))

    server = serve("127.0.0.1", 0)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with pytest.raises(urllib.error.HTTPError) as exc_info:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=5)
        assert exc_info.value.code == 503
        payload = json.loads(exc_info.value.read())
        assert payload == {"status": "unhealthy", "error": "bad_spec"}
    finally:
        server.shutdown()
