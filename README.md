# agent-ops

Helm charts and deploy code for running agents on the shared Ubuntu k3s node. The Mac holds this repo. Ubuntu builds `linux/amd64` images. Helm runs on the Mac.

This project uses the same host, cluster, SSH key, Docker daemon, and `localhost:5000` registry as RAGline. Isolation is the namespace, the Helm release, the remote checkout, and the Service port.

## Isolation

| | |
| --- | --- |
| Namespace / Helm release | `agent-ops` |
| Remote checkout | `/home/van/src/agent-ops` |
| Registry | `localhost:5000` |
| Node port | not 8000 |

Do not helm-upgrade `ragline`, resize or reuse `ragline-data-pvc`, or bind node port 8000. Do not run `./ssh-ubuntu.sh bootstrap` on this host. Bootstrap is for a new machine and stays behind `AGENT_OPS_BOOTSTRAP_FORCE=1`.

Host defaults are in `scripts/dev-env.env`. The command list and the lessons from the RAGline loop are in `workspace.md`.

## Layout

| Path | Purpose |
| --- | --- |
| `ssh-ubuntu.sh` | SSH, build, Helm, and smoke from the Mac |
| `scripts/` | Host defaults, image build, probe, and secret rendering |
| `charts/agent-ops/` | Helm chart (stub until a workload exists) |
| `services/<name>/` | Image build context (`Dockerfile`) |
| `helm.env.template` | Copy to `helm.env` and fill in locally |

## Secrets

These stay local and are listed in `.gitignore`:

- `helm.env` and other `.env` files
- `charts/agent-ops/values-local-secrets.yaml`
- `scripts/.ssh-passphrase`
- key material (`*.pem`, `*.key`) and kubeconfig copies

```bash
cp helm.env.template helm.env
./scripts/render-local-secret-values.sh
```

Passphrase lookup is an env var, then `~/.config/agent-ops/ssh-passphrase`, then `~/.config/ragline/ssh-passphrase`, then `scripts/.ssh-passphrase`.

## First deploy

There is no service image yet. After `services/<name>/Dockerfile` exists and the chart defines Deployment `agent-ops-<name>`:

```bash
./ssh-ubuntu.sh unlock
./ssh-ubuntu.sh push-src
./ssh-ubuntu.sh build <service> dev-<tag>
./ssh-ubuntu.sh deploy dev-<tag>
./ssh-ubuntu.sh rollout <service>
./ssh-ubuntu.sh smoke
```

`build` and `deploy` need the same tag. `push-src` does not copy `.git`, so pass the tag on `build`. The image pushed to the node registry is `localhost:5000/<service>:<tag>`. Rebuilds need a new tag while `imagePullPolicy` is `IfNotPresent`.
