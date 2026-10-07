"""One agent turn. Tests, evals, and the HTTP server all call this."""

from __future__ import annotations

import json
import sys
import time
import uuid
from pathlib import Path

from agent_ops.spec import AgentNotFoundError, AgentSpec, load_agents


def run_turn(
    agent: str,
    user_input: str,
    case_id: str | None = None,
    root: Path | None = None,
) -> dict:
    started = time.perf_counter()
    specs = load_agents(root)
    spec = specs.get(agent)
    if spec is None:
        raise AgentNotFoundError(agent)
    trace_id = uuid.uuid4().hex
    if spec.provider == "fake":
        if not spec.fake_output:
            result = _result(spec, trace_id, "", "bad_spec")
        else:
            result = _result(spec, trace_id, spec.fake_output, None)
    else:
        result = _result(spec, trace_id, "", "provider")
    _log(result, spec, case_id, started)
    return result


def _result(spec: AgentSpec, trace_id: str, output: str, error: str | None) -> dict:
    return {
        "agent": spec.name,
        "agent_version": spec.version,
        "output": output,
        "tool_calls": [],
        "usage": {"input_tokens": 0, "output_tokens": 0},
        "trace_id": trace_id,
        "error": error,
    }


def _log(result: dict, spec: AgentSpec, case_id: str | None, started: float) -> None:
    payload = {
        "trace_id": result["trace_id"],
        "agent": result["agent"],
        "agent_version": result["agent_version"],
        "provider": spec.provider,
        "case_id": case_id,
        "error": result["error"],
        "input_tokens": result["usage"]["input_tokens"],
        "output_tokens": result["usage"]["output_tokens"],
        "latency_ms": int((time.perf_counter() - started) * 1000),
    }
    print(json.dumps(payload), file=sys.stderr)
