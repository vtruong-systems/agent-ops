#!/usr/bin/env bash
# Install Docker, Git, and a node-local registry on the Ubuntu k3s host.
# Intended to run ON Ubuntu (via ./ssh-ubuntu.sh bootstrap). Does not deploy the app.
#
# The current workstation already shares the RAGline Ubuntu k3s node.
# Do not run this unless you are standing up a NEW host. On the shared node,
# Docker, k3s, registries.yaml, and localhost:5000 already exist; a run here
# can restart k3s and disrupt the ragline release.

set -euo pipefail

REGISTRY_PORT="${AGENT_OPS_REGISTRY_PORT:-5000}"
REMOTE_ROOT="${AGENT_OPS_REMOTE_ROOT:-/home/van/src/agent-ops}"
CONFIRM="${AGENT_OPS_BOOTSTRAP_CONFIRM:-}"
DOCKER_USER="${AGENT_OPS_DOCKER_USER:-van}"
REGISTRY_NAME="${AGENT_OPS_REGISTRY_NAME:-local-registry}"

if [[ "${CONFIRM}" != "yes" ]]; then
  echo "Refusing to mutate the Ubuntu host without AGENT_OPS_BOOTSTRAP_CONFIRM=yes"
  echo "This script installs docker.io and git, starts a local registry on port ${REGISTRY_PORT},"
  echo "writes /etc/rancher/k3s/registries.yaml, and may restart k3s."
  exit 2
fi

rootish() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

export DEBIAN_FRONTEND=noninteractive
LOG=/tmp/agent-ops-bootstrap.log
touch "${LOG}"
exec > >(tee -a "${LOG}") 2>&1
echo "bootstrap start $(date -Is)"
rootish apt-get update -y
rootish apt-get install -y docker.io git ca-certificates curl

if id "${DOCKER_USER}" >/dev/null 2>&1; then
  rootish usermod -aG docker "${DOCKER_USER}"
fi

rootish mkdir -p /etc/rancher/k3s
REG_FILE=/etc/rancher/k3s/registries.yaml
NEED_K3S_RESTART=0
if [[ ! -f "${REG_FILE}" ]] || ! grep -q "localhost:${REGISTRY_PORT}" "${REG_FILE}"; then
  NEED_K3S_RESTART=1
  rootish tee "${REG_FILE}" >/dev/null <<EOF
mirrors:
  "localhost:${REGISTRY_PORT}":
    endpoint:
      - "http://127.0.0.1:${REGISTRY_PORT}"
  "127.0.0.1:${REGISTRY_PORT}":
    endpoint:
      - "http://127.0.0.1:${REGISTRY_PORT}"
configs:
  "localhost:${REGISTRY_PORT}":
    tls:
      insecure_skip_verify: true
  "127.0.0.1:${REGISTRY_PORT}":
    tls:
      insecure_skip_verify: true
EOF
else
  echo "registries.yaml already has localhost:${REGISTRY_PORT}; leaving it in place"
fi

rootish systemctl enable --now docker

EXISTING_REG="$(rootish docker ps -a --format '{{.Names}} {{.Ports}}' | awk -v p=":${REGISTRY_PORT}->" '$0 ~ p {print $1; exit}')"
if [[ -n "${EXISTING_REG}" ]]; then
  echo "reusing existing registry container ${EXISTING_REG} on port ${REGISTRY_PORT}"
  rootish docker start "${EXISTING_REG}" >/dev/null || true
elif rootish docker inspect "${REGISTRY_NAME}" >/dev/null 2>&1; then
  rootish docker start "${REGISTRY_NAME}" >/dev/null
else
  rootish docker run -d --restart=always --name "${REGISTRY_NAME}" \
    -p "${REGISTRY_PORT}:5000" \
    registry:2
fi

rootish mkdir -p "${REMOTE_ROOT}"
if id "${DOCKER_USER}" >/dev/null 2>&1; then
  rootish chown -R "${DOCKER_USER}:${DOCKER_USER}" "${REMOTE_ROOT}"
fi

echo "bootstrap complete"
echo "docker=$(command -v docker)"
echo "git=$(command -v git)"
echo "registry=localhost:${REGISTRY_PORT}"
echo "checkout=${REMOTE_ROOT}"
if [[ "${NEED_K3S_RESTART}" -eq 1 ]]; then
  echo "restarting k3s to load registries.yaml"
  rootish systemctl restart k3s
  echo "k3s restarted"
else
  echo "k3s restart skipped"
fi
