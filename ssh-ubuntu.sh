#!/usr/bin/env bash
# Mac workstation helper for the Ubuntu k3s node.
# Default with no args is an interactive SSH shell.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/dev-env.env"
# shellcheck disable=SC1091
source "${ROOT}/scripts/ssh-unlock.sh"

usage() {
  cat <<EOF
Usage: ./ssh-ubuntu.sh <command> [args]

Commands:
  shell                 Interactive SSH session (default)
  unlock                Load the SSH key into the agent from a local passphrase file
  status                Remote host, docker, k3s, registry, git checkout
  probe                 Host inspection via kubectl debug (no SSH)
  check                 Mac + cluster + SSH connectivity report
  bootstrap             Do not use on the shared RAGline node; new hosts only
  push-src              rsync this workspace to the Ubuntu checkout
  github-setup          Copy the GitHub SSH identity to Ubuntu and test auth
  sync [branch]         Fetch and fast-forward the remote checkout
  build <service> [tag] Build linux/amd64 image and push to local registry
  deploy [tag]          helm upgrade --install from this Mac
  rollout <service>     Wait for a Deployment rollout
  smoke                 Port-forward the runtime and run fixture evals

Environment (see scripts/dev-env.env):
  AGENT_OPS_SSH_HOST AGENT_OPS_SSH_USER AGENT_OPS_SSH_IDENTITY
  AGENT_OPS_REMOTE_ROOT AGENT_OPS_REGISTRY AGENT_OPS_NAMESPACE
  AGENT_OPS_ALLOW_DIRTY=1 to override a dirty remote checkout
  SSH passphrase: ~/.config/agent-ops/ssh-passphrase,
                  ~/.config/ragline/ssh-passphrase, or scripts/.ssh-passphrase
EOF
}

ssh_base() {
  ssh -o IdentitiesOnly=yes -o ConnectTimeout=10 \
    -i "${AGENT_OPS_SSH_IDENTITY}" \
    "${AGENT_OPS_SSH_USER}@${AGENT_OPS_SSH_HOST}" "$@"
}

ssh_batch() {
  ssh -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 \
    -i "${AGENT_OPS_SSH_IDENTITY}" \
    "${AGENT_OPS_SSH_USER}@${AGENT_OPS_SSH_HOST}" "$@"
}

require_ssh() {
  if ! agent_ops_unlock_ssh; then
    exit 1
  fi
  if ! ssh_batch "echo ok" >/dev/null 2>&1; then
    echo "SSH login failed for ${AGENT_OPS_SSH_USER}@${AGENT_OPS_SSH_HOST}"
    exit 1
  fi
}

cmd_unlock() {
  agent_ops_unlock_ssh
}

allowlisted() {
  local svc="$1"
  if [[ -z "${AGENT_OPS_SERVICE_ALLOWLIST}" ]]; then
    return 0
  fi
  local item
  IFS=',' read -r -a items <<< "${AGENT_OPS_SERVICE_ALLOWLIST}"
  for item in "${items[@]}"; do
    if [[ "${item}" == "${svc}" ]]; then
      return 0
    fi
  done
  echo "service ${svc} is not in the allowlist: ${AGENT_OPS_SERVICE_ALLOWLIST}"
  exit 1
}

cmd_shell() {
  agent_ops_unlock_ssh || true
  exec ssh -o IdentitiesOnly=yes -i "${AGENT_OPS_SSH_IDENTITY}" \
    "${AGENT_OPS_SSH_USER}@${AGENT_OPS_SSH_HOST}"
}

cmd_status() {
  require_ssh
  ssh_batch "bash -s" <<EOF
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
echo host=\$(hostname)
echo user=\$(whoami)
echo docker=\$(command -v docker || echo MISSING)
echo git=\$(command -v git || echo MISSING)
echo k3s=\$(k3s --version 2>/dev/null | head -1 || echo MISSING)
echo registry_yaml=\$([ -f /etc/rancher/k3s/registries.yaml ] && echo present || echo MISSING)
docker ps --format '{{.Names}} {{.Status}} {{.Ports}}' 2>/dev/null | awk '/5000/ {print}' || true
echo checkout=${AGENT_OPS_REMOTE_ROOT}
if [ -d "${AGENT_OPS_REMOTE_ROOT}/.git" ]; then
  git -C "${AGENT_OPS_REMOTE_ROOT}" rev-parse --abbrev-ref HEAD
  git -C "${AGENT_OPS_REMOTE_ROOT}" rev-parse --short HEAD
  git -C "${AGENT_OPS_REMOTE_ROOT}" status -sb
elif [ -d "${AGENT_OPS_REMOTE_ROOT}" ]; then
  echo "checkout present but not a git repo"
  ls -ld "${AGENT_OPS_REMOTE_ROOT}"
else
  echo "checkout missing"
fi
EOF
}

cmd_probe() {
  exec "${ROOT}/scripts/ubuntu-host-probe.sh"
}

cmd_check() {
  exec "${ROOT}/scripts/check-dev-env.sh"
}

cmd_bootstrap() {
  echo "This Ubuntu node already runs RAGline k3s, Docker, and localhost:5000."
  echo "Refuse bootstrap unless this is a different machine and you set AGENT_OPS_BOOTSTRAP_FORCE=1"
  if [[ "${AGENT_OPS_BOOTSTRAP_FORCE:-}" != "1" ]]; then
    exit 2
  fi
  require_ssh
  ssh_batch "cat > /tmp/agent-ops-ubuntu-bootstrap.sh && chmod 700 /tmp/agent-ops-ubuntu-bootstrap.sh" <<EOF
export AGENT_OPS_BOOTSTRAP_CONFIRM=yes
export AGENT_OPS_REMOTE_ROOT='${AGENT_OPS_REMOTE_ROOT}'
export AGENT_OPS_REGISTRY_PORT='${AGENT_OPS_REGISTRY_PORT}'
export AGENT_OPS_DOCKER_USER='${AGENT_OPS_SSH_USER}'
$(cat "${ROOT}/scripts/ubuntu-bootstrap.sh")
EOF

  if ssh_batch "sudo -n true" >/dev/null 2>&1; then
    ssh_batch "AGENT_OPS_BOOTSTRAP_CONFIRM=yes bash /tmp/agent-ops-ubuntu-bootstrap.sh"
    return
  fi

  echo "sudo on Ubuntu requires a password; running bootstrap as host root through k3s"
  kubectl -n kube-system delete pod agent-ops-host-bootstrap --ignore-not-found=true --wait=true >/dev/null
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: agent-ops-host-bootstrap
  namespace: kube-system
spec:
  restartPolicy: Never
  hostNetwork: true
  hostPID: true
  containers:
    - name: bootstrap
      image: ${AGENT_OPS_PROBE_IMAGE}
      imagePullPolicy: IfNotPresent
      securityContext:
        privileged: true
      command: ["chroot", "/host", "/bin/bash", "/tmp/agent-ops-ubuntu-bootstrap.sh"]
      volumeMounts:
        - name: host
          mountPath: /host
  volumes:
    - name: host
      hostPath:
        path: /
        type: Directory
EOF

  echo "waiting for apt, docker, and registry setup"
  local i
  for i in $(seq 1 120); do
    if ssh_batch "grep -q '^bootstrap complete' /tmp/agent-ops-bootstrap.log" >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done

  kubectl wait --for=condition=Ready node --all --timeout=180s >/dev/null 2>&1 || true
  echo "--- bootstrap log ---"
  ssh_batch "tail -n 60 /tmp/agent-ops-bootstrap.log" || true
  echo "--- status ---"
  cmd_status
  kubectl -n kube-system delete pod agent-ops-host-bootstrap --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
}

cmd_github_setup() {
  require_ssh
  local key="${AGENT_OPS_GITHUB_IDENTITY}"
  local pub="${key}.pub"
  if [[ "${key}" == *.pem ]]; then
    pub="${key%.pem}.pub"
  fi
  if [[ ! -f "${key}" || ! -f "${pub}" ]]; then
    echo "GitHub identity not found: ${key} / ${pub}"
    exit 1
  fi
  local base
  base="$(basename "${key}")"
  local pubbase
  pubbase="$(basename "${pub}")"
  scp -o BatchMode=yes -o IdentitiesOnly=yes -i "${AGENT_OPS_SSH_IDENTITY}" \
    "${key}" "${pub}" \
    "${AGENT_OPS_SSH_USER}@${AGENT_OPS_SSH_HOST}:/home/${AGENT_OPS_SSH_USER}/.ssh/"
  ssh_batch "bash -s" <<EOF
set -euo pipefail
chmod 700 "\$HOME/.ssh"
chmod 600 "\$HOME/.ssh/${base}"
chmod 644 "\$HOME/.ssh/${pubbase}"
touch "\$HOME/.ssh/config" "\$HOME/.ssh/known_hosts"
chmod 600 "\$HOME/.ssh/config" "\$HOME/.ssh/known_hosts"
if ! grep -q "IdentityFile ~/.ssh/${base}" "\$HOME/.ssh/config"; then
  cat >> "\$HOME/.ssh/config" <<CFG

Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/${base}
  IdentitiesOnly yes
CFG
fi
ssh-keyscan -t ed25519,ecdsa,rsa github.com >> "\$HOME/.ssh/known_hosts" 2>/dev/null
sort -u "\$HOME/.ssh/known_hosts" -o "\$HOME/.ssh/known_hosts"
ssh -o BatchMode=yes -o IdentitiesOnly=yes -T git@github.com || true
EOF
}

cmd_push_src() {
  require_ssh
  ssh_batch "mkdir -p '${AGENT_OPS_REMOTE_ROOT}'"
  echo "rsync ${ROOT}/ -> ${AGENT_OPS_SSH_USER}@${AGENT_OPS_SSH_HOST}:${AGENT_OPS_REMOTE_ROOT}/"
  rsync -az --stats \
    --exclude node_modules \
    --exclude .venv \
    --exclude venv \
    --exclude __pycache__ \
    --exclude .git \
    --exclude helm.env \
    --exclude values-local-secrets.yaml \
    --exclude scripts/.ssh-passphrase \
    --exclude eval-report.json \
    --exclude .pytest_cache \
    --exclude '*.egg-info' \
    -e "ssh -o BatchMode=yes -o IdentitiesOnly=yes -i ${AGENT_OPS_SSH_IDENTITY}" \
    "${ROOT}/" \
    "${AGENT_OPS_SSH_USER}@${AGENT_OPS_SSH_HOST}:${AGENT_OPS_REMOTE_ROOT}/"
  ssh_batch "ls -ld '${AGENT_OPS_REMOTE_ROOT}' && test -x '${AGENT_OPS_REMOTE_ROOT}/scripts/build-service.sh' && echo build-script=ok"
}

cmd_sync() {
  require_ssh
  local branch="${1:-}"
  ssh_batch "bash -s" <<EOF
set -euo pipefail
cd "${AGENT_OPS_REMOTE_ROOT}"
if [ ! -d .git ]; then
  echo "remote checkout is missing git at ${AGENT_OPS_REMOTE_ROOT}"
  echo "clone the repo there first, or use ./ssh-ubuntu.sh push-src"
  exit 1
fi
if [ -n "\$(git status --porcelain)" ] && [ "${AGENT_OPS_ALLOW_DIRTY:-}" != "1" ]; then
  echo "remote checkout is dirty; set AGENT_OPS_ALLOW_DIRTY=1 to override"
  git status -sb
  exit 1
fi
git fetch --prune
if [ -n "${branch}" ]; then
  git checkout "${branch}"
fi
git pull --ff-only
git rev-parse --abbrev-ref HEAD
git rev-parse --short HEAD
EOF
}

cmd_build() {
  require_ssh
  local service="${1:-}"
  local tag="${2:-}"
  if [[ -z "${service}" ]]; then
    echo "usage: ./ssh-ubuntu.sh build <service> [tag]"
    exit 1
  fi
  allowlisted "${service}"
  ssh_batch "bash -s" <<EOF
set -euo pipefail
cd "${AGENT_OPS_REMOTE_ROOT}"
if [ ! -x ./scripts/build-service.sh ]; then
  echo "build-service.sh not found in ${AGENT_OPS_REMOTE_ROOT}"
  echo "push source first: ./ssh-ubuntu.sh push-src"
  exit 1
fi
if [ -d .git ] && [ -n "\$(git status --porcelain)" ] && [ "${AGENT_OPS_ALLOW_DIRTY:-}" != "1" ]; then
  echo "remote checkout is dirty; set AGENT_OPS_ALLOW_DIRTY=1 to override"
  exit 1
fi
TAG="${tag}"
if [ -z "\${TAG}" ]; then
  if [ -d .git ]; then
    TAG="dev-\$(git rev-parse --short HEAD)"
  else
    TAG="dev-local"
  fi
fi
echo "building ${service} as linux/amd64 tag=\${TAG}"
export AGENT_OPS_DOCKER_NETWORK="${AGENT_OPS_DOCKER_NETWORK:-host}"
export AGENT_OPS_DOCKER_NO_CACHE="${AGENT_OPS_DOCKER_NO_CACHE:-0}"
export AGENT_OPS_IMAGE_PREFIX="${AGENT_OPS_IMAGE_PREFIX}"
export DOCKER_DEFAULT_PLATFORM=linux/amd64
./scripts/build-service.sh "${service}" "\${TAG}"
docker tag "${AGENT_OPS_IMAGE_PREFIX}-${service}:\${TAG}" "${AGENT_OPS_REGISTRY}/${AGENT_OPS_IMAGE_PREFIX}-${service}:\${TAG}"
docker push "${AGENT_OPS_REGISTRY}/${AGENT_OPS_IMAGE_PREFIX}-${service}:\${TAG}"
echo "pushed ${AGENT_OPS_REGISTRY}/${AGENT_OPS_IMAGE_PREFIX}-${service}:\${TAG}"
EOF
}

cmd_deploy() {
  local tag="${1:-}"
  if [[ -z "${tag}" ]]; then
    echo "usage: ./ssh-ubuntu.sh deploy <tag>"
    echo "the tag must match images already pushed to ${AGENT_OPS_REGISTRY}"
    exit 1
  fi
  if [[ ! -d "${ROOT}/${AGENT_OPS_CHART_DIR}" ]]; then
    echo "chart not found: ${AGENT_OPS_CHART_DIR}"
    echo "add a Helm chart before deploy"
    exit 1
  fi
  local -a helm_args=(
    upgrade --install "${AGENT_OPS_RELEASE}" "${ROOT}/${AGENT_OPS_CHART_DIR}"
    --namespace "${AGENT_OPS_NAMESPACE}"
    --create-namespace
  )
  if [[ -f "${ROOT}/${AGENT_OPS_VALUES_FILE}" ]]; then
    helm_args+=(--values "${ROOT}/${AGENT_OPS_VALUES_FILE}")
  fi
  if [[ -f "${ROOT}/${AGENT_OPS_SECRETS_VALUES}" ]]; then
    helm_args+=(--values "${ROOT}/${AGENT_OPS_SECRETS_VALUES}")
    echo "including gitignored secrets overlay ${AGENT_OPS_SECRETS_VALUES}"
  else
    echo "no secrets overlay at ${AGENT_OPS_SECRETS_VALUES}; run scripts/render-local-secret-values.sh if needed"
  fi
  helm_args+=(
    --set "global.registry=${AGENT_OPS_REGISTRY}"
    --set "global.imageTag=${tag}"
    --set "global.imagePullPolicy=IfNotPresent"
  )
  helm "${helm_args[@]}"
}

cmd_rollout() {
  local service="${1:-}"
  if [[ -z "${service}" ]]; then
    echo "usage: ./ssh-ubuntu.sh rollout <service>"
    exit 1
  fi
  allowlisted "${service}"
  kubectl -n "${AGENT_OPS_NAMESPACE}" rollout status "deployment/${AGENT_OPS_RELEASE}-${service}" --timeout=180s
}

cmd_smoke() (
  echo "cluster:"
  kubectl get nodes
  echo
  echo "release:"
  helm list -n "${AGENT_OPS_NAMESPACE}" || true
  echo
  echo "pods:"
  kubectl get pods -n "${AGENT_OPS_NAMESPACE}" -o wide || true
  echo
  echo "services:"
  kubectl get svc -n "${AGENT_OPS_NAMESPACE}" || true
  echo
  local python_bin="${AGENT_OPS_PYTHON:-}"
  if [[ -z "${python_bin}" ]]; then
    if [[ -x "${ROOT}/.venv/bin/python" ]]; then
      python_bin="${ROOT}/.venv/bin/python"
    else
      python_bin="python3"
    fi
  fi

  local forward_log
  forward_log="$(mktemp -t agent-ops-port-forward.XXXXXX)"
  local forward_pid=""
  cleanup_smoke() {
    if [[ -n "${forward_pid}" ]]; then
      kill "${forward_pid}" >/dev/null 2>&1 || true
      wait "${forward_pid}" >/dev/null 2>&1 || true
    fi
    rm -f "${forward_log}"
  }
  trap cleanup_smoke EXIT

  echo
  echo "port-forwarding service/agent-ops-runtime to 127.0.0.1:${AGENT_OPS_LOCAL_PORT}"
  kubectl -n "${AGENT_OPS_NAMESPACE}" port-forward \
    service/agent-ops-runtime "${AGENT_OPS_LOCAL_PORT}:8080" \
    >"${forward_log}" 2>&1 &
  forward_pid=$!

  local health_url="http://127.0.0.1:${AGENT_OPS_LOCAL_PORT}/healthz"
  local ready=0
  local attempt
  for attempt in $(seq 1 30); do
    if curl -fsS --connect-timeout 1 "${health_url}" >/dev/null 2>&1; then
      ready=1
      break
    fi
    if ! kill -0 "${forward_pid}" >/dev/null 2>&1; then
      echo "port-forward stopped unexpectedly"
      sed -n '1,120p' "${forward_log}"
      return 1
    fi
    sleep 0.5
  done
  if [[ "${ready}" != "1" ]]; then
    echo "runtime did not become healthy at ${health_url}"
    sed -n '1,120p' "${forward_log}"
    return 1
  fi

  "${python_bin}" -m agent_ops.eval \
    --provider fake \
    --target "http://127.0.0.1:${AGENT_OPS_LOCAL_PORT}" \
    --report "${AGENT_OPS_SMOKE_REPORT:-${ROOT}/eval-report.json}"

  if [[ -n "${AGENT_OPS_SMOKE_PORT}" ]]; then
    UI_URL="http://${AGENT_OPS_SSH_HOST}:${AGENT_OPS_SMOKE_PORT}"
    echo "GET ${UI_URL}"
    curl -sS -o /dev/null -w "http_code=%{http_code} time=%{time_total}\n" --connect-timeout 5 "${UI_URL}" || true
  fi
)

COMMAND="${1:-shell}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "${COMMAND}" in
  shell|ssh) cmd_shell ;;
  unlock) cmd_unlock ;;
  status) cmd_status ;;
  probe) cmd_probe ;;
  check) cmd_check ;;
  bootstrap) cmd_bootstrap ;;
  github-setup) cmd_github_setup ;;
  push-src) cmd_push_src ;;
  sync) cmd_sync "$@" ;;
  build) cmd_build "$@" ;;
  deploy) cmd_deploy "$@" ;;
  rollout) cmd_rollout "$@" ;;
  smoke) cmd_smoke ;;
  -h|--help|help) usage ;;
  *)
    echo "unknown command: ${COMMAND}"
    usage
    exit 1
    ;;
esac
