import shutil
import subprocess
from pathlib import Path

import pytest
import yaml


ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts" / "agent-ops"


def render_chart() -> list[dict]:
    if not shutil.which("helm"):
        pytest.skip("helm is not installed")
    result = subprocess.run(
        ["helm", "template", "agent-ops", str(CHART), "-f", str(CHART / "values-ci.yaml")],
        check=True,
        capture_output=True,
        text=True,
    )
    return [item for item in yaml.safe_load_all(result.stdout) if item]


def test_chart_renders_runtime_with_safe_defaults():
    resources = render_chart()
    by_kind = {item["kind"]: item for item in resources}

    deployment = by_kind["Deployment"]
    assert deployment["metadata"]["name"] == "agent-ops-runtime"
    container = deployment["spec"]["template"]["spec"]["containers"][0]
    assert container["image"] == "localhost:5000/agent-ops-runtime:ci-test-0000000"
    assert container["imagePullPolicy"] == "IfNotPresent"
    assert container["securityContext"]["runAsNonRoot"] is True
    assert container["securityContext"]["readOnlyRootFilesystem"] is True

    service = by_kind["Service"]
    assert service["metadata"]["name"] == "agent-ops-runtime"
    assert service["spec"]["type"] == "ClusterIP"
    assert "nodePort" not in service["spec"]["ports"][0]
    assert "Secret" not in by_kind
