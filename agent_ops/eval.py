"""Fixture and live eval runner. Same cases run in-process or against an HTTP build."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import yaml

from agent_ops.spec import AgentNotFoundError, AgentSpec, SpecError, load_agents, repo_root
from agent_ops.turn import run_turn

LIVE_PROVIDERS = {"openai", "azure_openai"}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run agent eval cases")
    parser.add_argument("--suite", default="evals/cases")
    parser.add_argument("--provider", choices=["fake", "live"], required=True)
    parser.add_argument("--agent", default="")
    parser.add_argument("--target", default="inproc")
    parser.add_argument("--report", default="eval-report.json")
    args = parser.parse_args(argv)

    root = repo_root()
    suite = Path(args.suite)
    if not suite.is_absolute():
        suite = root / suite
    try:
        specs = load_agents(root)
        cases = load_cases(suite)
    except (SpecError, yaml.YAMLError, OSError) as exc:
        print(f"eval setup failed: {exc}", file=sys.stderr)
        return 1

    results = [run_case(case, specs, args.provider, args.agent, args.target, root) for case in cases]
    report = {"target": args.target, "provider_mode": args.provider, "results": results}
    report_path = Path(args.report)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    active = [item for item in results if item["status"] == "active"]
    failed = [item for item in active if not item["pass"]]
    skipped = [item for item in results if item["status"] == "skipped"]
    print(
        f"target={args.target} active={len(active)} pass={len(active) - len(failed)} "
        f"fail={len(failed)} skip={len(skipped)} report={report_path}"
    )
    for item in failed:
        print(f"FAIL {item['id']} agent={item['agent']} error={item.get('error')}")
    return 1 if failed else 0


def load_cases(suite: Path) -> list[dict]:
    if not suite.is_dir():
        raise SpecError(f"missing suite {suite}")
    cases = []
    for path in sorted(suite.rglob("*.yaml")):
        raw = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(raw, dict):
            raise SpecError(f"{path} must be a mapping")
        for key in ("id", "agent", "input", "scorers"):
            if key not in raw:
                raise SpecError(f"{path} missing {key}")
        raw["status"] = raw.get("status") or "active"
        raw["_path"] = str(path)
        cases.append(raw)
    return cases


def run_case(case: dict, specs: dict[str, AgentSpec], mode: str, only_agent: str, target: str, root: Path) -> dict:
    spec = specs.get(case["agent"])
    base = {
        "id": case["id"],
        "agent": case["agent"],
        "agent_version": spec.version if spec else None,
        "provider": spec.provider if spec else None,
        "model": spec.model if spec else "",
        "status": case["status"],
        "trace_id": None,
        "error": None,
        "pass": False,
        "scorers": [],
    }
    if only_agent and case["agent"] != only_agent:
        return {**base, "status": "skipped", "pass": True, "error": "agent_filter"}
    if spec is None:
        return {**base, "error": "unknown_agent"}
    skip = skip_reason(spec, mode)
    if skip:
        return {**base, "status": "skipped", "pass": True, "error": skip}
    try:
        result = invoke(case, target, root)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return {**base, "error": f"target: {exc}"}
    base["trace_id"] = result.get("trace_id")
    base["error"] = result.get("error")
    expects_error = any(item.get("name") == "error_code" for item in case["scorers"])
    if result.get("error") and not expects_error:
        base["scorers"] = [{"name": item.get("name"), "pass": False} for item in case["scorers"]]
        return base
    scored = []
    for item in case["scorers"]:
        name = item.get("name")
        try:
            ok = score(name, result.get("output") or "", result.get("error"), item.get("value"), spec)
        except (TypeError, ValueError, json.JSONDecodeError):
            ok = False
        scored.append({"name": name, "pass": ok})
    base["scorers"] = scored
    base["pass"] = all(item["pass"] for item in scored) and bool(scored)
    return base


def skip_reason(spec: AgentSpec, mode: str) -> str | None:
    if mode == "fake" and spec.provider != "fake":
        return "not_fake"
    if mode == "live" and spec.provider not in LIVE_PROVIDERS:
        return "not_live"
    if mode == "live" and spec.live_secret and not os.environ.get(spec.live_secret, "").strip():
        return "missing_secret"
    return None


def invoke(case: dict, target: str, root: Path) -> dict:
    if target == "inproc":
        return run_turn(case["agent"], case["input"], case["id"], root)
    url = target.rstrip("/") + "/turns"
    body = json.dumps({"agent": case["agent"], "input": case["input"], "case_id": case["id"]}).encode("utf-8")
    request = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    deadline = time.monotonic() + 15
    while True:
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise OSError(f"HTTP {exc.code} {detail}") from exc
        except urllib.error.URLError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.3)


def score(name: str, output: str, error: str | None, value, spec: AgentSpec) -> bool:
    if name == "contains":
        return str(value) in output
    if name == "exact":
        return output.strip() == str(value).strip()
    if name == "schema":
        parsed = json.loads(output)
        if not isinstance(parsed, dict):
            return False
        keys = value if isinstance(value, list) else []
        return all(key in parsed for key in keys)
    if name == "max_chars":
        limit = spec.max_output_chars if value is None else int(value)
        return len(output) <= limit
    if name == "error_code":
        return error == value
    raise ValueError(f"unknown scorer {name}")


if __name__ == "__main__":
    raise SystemExit(main())
