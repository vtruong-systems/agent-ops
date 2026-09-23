# agent-ops

Workspace for learning and deploying agents (local Helm/k3s first, later Foundry and other external runtimes).

This tree was seeded from the RAGline Mac → Ubuntu k3s loop. It is a new project, not a copy of the RAGline application.

## Current truth

- Same Ubuntu laptop, same k3s cluster, same kubeconfig, same SSH key (`~/.ssh/mac-ubuntu`), same Docker daemon, same node-local registry `localhost:5000` as RAGline.
- Mac still edits; Ubuntu still builds `linux/amd64`; Helm still runs on the Mac.
- Isolation is **not** a second cluster. It is namespace `agent-ops`, Helm release `agent-ops`, remote checkout `/home/van/src/agent-ops`, and image names prefixed `agent-ops-`.
- Do **not** helm-upgrade `ragline`, resize or reuse `ragline-data-pvc`, or bind node port **8000** (RAGline chat UI already owns it).
- Do **not** run `./ssh-ubuntu.sh bootstrap` on this host. Docker, k3s, `/etc/rancher/k3s/registries.yaml`, and the registry container are already there. Bootstrap is gated behind `AGENT_OPS_BOOTSTRAP_FORCE=1` for a future new machine only.
- GitHub SSH on Ubuntu is already configured from RAGline (`github-setup` is optional).
- Foundry, evaluations, and a second cluster come later. First runtime is Helm charts and pods in `agent-ops`.

## Topology

| Component | Shared with RAGline | agent-ops value |
| --- | --- | --- |
| MacBook | yes | Source, Git, `kubectl`, Helm, browser |
| Ubuntu host | yes | `van@192.168.68.62` |
| k3s API | yes | `https://192.168.68.62:6443` |
| Docker / registry | yes | `localhost:5000` (existing `ragline-registry` is fine) |
| Namespace / Helm release | **no** | `agent-ops` |
| Remote checkout | **no** | `/home/van/src/agent-ops` |
| Images | shared registry, distinct names | `localhost:5000/<service>:<immutable-tag>` |
| Node LoadBalancer port | **no** | not 8000; set `AGENT_OPS_SMOKE_PORT` when a Service exists |

`kubectl` context is the same cluster. Always pass `-n agent-ops` (the scripts do). `kubectl get pods -n ragline` is the other product.

## Commands

```text
./ssh-ubuntu.sh check
./ssh-ubuntu.sh probe
./ssh-ubuntu.sh shell
./ssh-ubuntu.sh unlock
./ssh-ubuntu.sh status
./ssh-ubuntu.sh push-src
./ssh-ubuntu.sh sync [branch]
./ssh-ubuntu.sh build <service> [tag]
./ssh-ubuntu.sh deploy <tag>
./ssh-ubuntu.sh rollout <service>
./ssh-ubuntu.sh smoke
```

`bootstrap` and `github-setup` exist for a new host. They are not part of the daily loop on this node.

Defaults live in `scripts/dev-env.env`. SSH passphrase lookup:

1. `~/.config/agent-ops/ssh-passphrase`
2. `~/.config/ragline/ssh-passphrase` (same key; preferred while sharing the host)
3. `scripts/.ssh-passphrase`

Do not commit passphrases or `helm.env`.

## Daily loop (once there is a service image)

```bash
./ssh-ubuntu.sh unlock
./ssh-ubuntu.sh push-src
AGENT_OPS_ALLOW_DIRTY=1 ./ssh-ubuntu.sh build <service>
./ssh-ubuntu.sh deploy dev-<git-sha>
./ssh-ubuntu.sh rollout <service>
./ssh-ubuntu.sh smoke
```

Lessons carried over from RAGline:

1. Never reuse an image tag while `imagePullPolicy` is `IfNotPresent`. Bump the tag (`dev-<sha>-r2`) after a rebuild.
2. Push to `localhost:5000` on the node, or import into containerd. Do not expect Kubernetes to accept a local `docker push` from the Mac.
3. Helm cannot shrink an existing PVC. Size agent-ops volumes independently of RAGline.
4. Do not put keys in committed values. Use `helm.env` (gitignored) and `./scripts/render-local-secret-values.sh`.
5. Use `AGENT_OPS_DOCKER_NETWORK=host` if Docker bridge DNS/IPv6 breaks package installs in builds.
6. Keep a service allowlist in `AGENT_OPS_SERVICE_ALLOWLIST` once names are stable. Empty means any name under `services/`.
7. Helm runs on the Mac. Image builds run on Ubuntu.

## Layout

| Path | Purpose |
| --- | --- |
| `ssh-ubuntu.sh` | Mac helper for SSH, build, Helm, smoke |
| `scripts/dev-env.env` | Host, namespace, registry, chart paths |
| `scripts/ssh-unlock.sh` / `ssh-askpass.sh` | Non-interactive SSH key unlock |
| `scripts/check-dev-env.sh` | Connectivity report |
| `scripts/ubuntu-host-probe.sh` | k3s node probe without SSH |
| `scripts/ubuntu-bootstrap.sh` | New-host only; blocked on this shared node |
| `scripts/build-service.sh` | Per-service Docker build on Ubuntu |
| `scripts/render-local-secret-values.sh` | Gitignored Helm secrets overlay |
| `charts/agent-ops/` | Helm chart (stub until a real workload exists) |
| `services/` | Dockerized workloads (`services/<name>/Dockerfile`) |
| `helm.env.template` | Copy to `helm.env`; never commit the filled file |

## Not copied from RAGline

Application code, Helm product values, `helm.env` keys, GitHub PATs, and the `ragline` chart. Those stay in the RAGline workspace.

## Next

1. Decide the first pod (hello-world, agent runtime, or Foundry sidecar).
2. Add `services/<name>/Dockerfile` and set `AGENT_OPS_SERVICE_ALLOWLIST`.
3. Fill `charts/agent-ops` with a Deployment that pulls `localhost:5000/<name>:<tag>`. Use a Service port other than 8000.
4. Prove check → push-src → build → deploy → rollout → smoke on namespace `agent-ops` without touching `ragline`.
5. Add evaluation later; do not block the first Helm loop on it.
