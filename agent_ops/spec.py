"""Load agent specs from agents/<name>/agent.yaml."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

import yaml


class SpecError(Exception):
    """A spec file is missing a required field or disagrees with its path."""


class AgentNotFoundError(Exception):
    """No spec exists for the requested agent name."""


@dataclass(frozen=True)
class AgentSpec:
    name: str
    version: int
    provider: str
    model: str
    instructions: str
    fake_output: str | None
    tools: tuple[str, ...]
    max_turns: int
    timeout_seconds: int
    max_output_chars: int

    @property
    def live_secret(self) -> str | None:
        if self.provider == "openai":
            return "OPENAI_API_KEY"
        if self.provider == "azure_openai":
            return "AZURE_OPENAI_API_KEY"
        return None


def repo_root() -> Path:
    env = os.environ.get("AGENT_OPS_ROOT")
    if env:
        return Path(env)
    cwd = Path.cwd()
    if (cwd / "agents").is_dir():
        return cwd
    raise SpecError("agents/ not found; set AGENT_OPS_ROOT")


def load_agent(path: Path) -> AgentSpec:
    raw = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise SpecError(f"{path} must be a mapping")
    name = str(raw.get("name", "")).strip()
    if not name or name != path.parent.name:
        raise SpecError(f"{path} name must match directory {path.parent.name}")
    provider = str(raw.get("provider", "")).strip()
    if provider not in {"fake", "openai", "azure_openai"}:
        raise SpecError(f"{path} provider must be fake, openai, or azure_openai")
    limits = raw.get("limits") or {}
    if not isinstance(limits, dict):
        raise SpecError(f"{path} limits must be a mapping")
    tools = raw.get("tools") or []
    if not isinstance(tools, list) or not all(isinstance(item, str) for item in tools):
        raise SpecError(f"{path} tools must be a list of strings")
    fake_output = raw.get("fake_output")
    if fake_output is not None:
        fake_output = str(fake_output)
    return AgentSpec(
        name=name,
        version=int(raw.get("version", 0)),
        provider=provider,
        model=str(raw.get("model") or ""),
        instructions=str(raw.get("instructions") or ""),
        fake_output=fake_output,
        tools=tuple(tools),
        max_turns=int(limits.get("max_turns", 1)),
        timeout_seconds=int(limits.get("timeout_seconds", 30)),
        max_output_chars=int(limits.get("max_output_chars", 2000)),
    )


def load_agents(root: Path | None = None) -> dict[str, AgentSpec]:
    base = root or repo_root()
    agents_dir = base / "agents"
    if not agents_dir.is_dir():
        raise SpecError(f"missing {agents_dir}")
    found: dict[str, AgentSpec] = {}
    for path in sorted(agents_dir.glob("*/agent.yaml")):
        spec = load_agent(path)
        found[spec.name] = spec
    return found
