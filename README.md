# agent-ops

`agent-ops` is a production-minded reference implementation for building, evaluating, packaging, and operating agent systems.

The project has three intended outcomes:

1. Develop hands-on expertise with agent runtimes, evaluations, tools, observability, security, and orchestration.
2. Produce concrete architecture and implementation evidence that can support consulting work.
3. Establish a reusable pattern that can be adapted for deployment in client environments.

The first milestone uses a deterministic `hello` agent to prove the delivery contract without model or provider variability:

```text
agent spec -> turn function -> fixture eval -> runtime image -> HTTP eval
           -> Helm deployment -> port-forwarded pod eval
```

Tests, image verification, and the deployed service execute the same agent specifications and evaluation cases.

## Current implementation

- Python agent-spec loader and turn contract
- Deterministic `hello` agent
- Fixture eval CLI with in-process and HTTP targets
- Runtime HTTP service with `/healthz` and `/turns`
- Non-root Python 3.12 runtime image
- Image verification both inside the container and over HTTP
- Helm Deployment and ClusterIP Service with probes and container hardening
- GitHub Actions source, image, HTTP, and chart validation
- Mac-to-Ubuntu build and k3s deployment scripts

Live providers, tools, memory, and multi-agent orchestration intentionally follow this deterministic foundation.

## Local validation

```bash
python -m pip install -e '.[dev]'
pytest -q
python -m agent_ops.eval --provider fake
helm lint charts/agent-ops
helm template agent-ops charts/agent-ops -f charts/agent-ops/values-ci.yaml
```

Docker builds for the workstation loop run on the Ubuntu host, not the Mac.

## Ubuntu and k3s deployment

The Mac holds this repository and runs Helm. The shared Ubuntu host builds `linux/amd64` images and runs k3s.

```bash
./ssh-ubuntu.sh unlock
./ssh-ubuntu.sh check
./ssh-ubuntu.sh push-src
./ssh-ubuntu.sh build runtime dev-<immutable-tag>
./ssh-ubuntu.sh deploy dev-<immutable-tag>
./ssh-ubuntu.sh rollout runtime
./ssh-ubuntu.sh smoke
```

`build` verifies the fixture suite inside the image and against its HTTP server before pushing. `smoke` port-forwards the ClusterIP service and runs the same HTTP suite against the deployed pod.

Do not reuse an image tag while `imagePullPolicy` is `IfNotPresent`.

## Shared-cluster isolation

This project shares the Ubuntu host, k3s cluster, SSH key, Docker daemon, and `localhost:5000` registry with RAGline. Its boundaries are:

| Boundary | agent-ops value |
| --- | --- |
| Namespace | `agent-ops` |
| Helm release | `agent-ops` |
| Remote source | `/home/van/src/agent-ops` |
| Runtime image | `localhost:5000/agent-ops-runtime:<tag>` |
| Service | ClusterIP `agent-ops-runtime:8080` |

Do not helm-upgrade `ragline`, reuse `ragline-data-pvc`, or bind node port 8000. Do not run `./ssh-ubuntu.sh bootstrap` on the shared host.

## Client adaptation points

The repository separates reusable behavior from environment-specific configuration:

- `agents/` — versioned agent behavior and limits
- `evals/` — portable acceptance and regression cases
- `agent_ops/` — runtime, provider, and evaluation contracts
- `services/` — deployable image definitions
- `charts/agent-ops/` — Kubernetes runtime and operational defaults
- `scripts/dev-env.env` — workstation and lab-host settings
- `values-local.yaml` and secret overlays — environment-specific deployment values

A client implementation should replace lab-specific host and registry settings, integrate the client's identity and secret systems, and apply its network, policy, observability, and availability requirements without forking the agent contract.

## Secrets

Local and provider secrets remain outside Git:

- `helm.env`
- `charts/agent-ops/values-local-secrets.yaml`
- `scripts/.ssh-passphrase`
- private keys and kubeconfig copies

```bash
cp helm.env.template helm.env
./scripts/render-local-secret-values.sh
```

See [design.md](design.md) for the target architecture and phased roadmap, and [workspace.md](workspace.md) for the lab topology and operating commands.
