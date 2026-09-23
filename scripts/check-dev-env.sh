#!/usr/bin/env bash
# Validate Mac workstation connectivity to the Ubuntu k3s node and the intended
# Mac-edit / Ubuntu-build development loop. Does not change cluster state.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/dev-env.env"
# shellcheck disable=SC1091
source "${ROOT}/scripts/ssh-unlock.sh"

PASS=0
FAIL=0
WARN=0

ok() { echo "PASS  $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL  $*"; FAIL=$((FAIL + 1)); }
warn() { echo "WARN  $*"; WARN=$((WARN + 1)); }

echo "agent-ops development environment check"
echo "host=${AGENT_OPS_SSH_USER}@${AGENT_OPS_SSH_HOST}"
echo "api=${AGENT_OPS_K8S_API}"
echo "namespace=${AGENT_OPS_NAMESPACE}"
echo

if ping -c 1 -W 2000 "${AGENT_OPS_SSH_HOST}" >/dev/null 2>&1; then
  ok "ping ${AGENT_OPS_SSH_HOST}"
else
  bad "ping ${AGENT_OPS_SSH_HOST}"
fi

if [[ -f "${AGENT_OPS_SSH_IDENTITY}" ]]; then
  ok "ssh identity ${AGENT_OPS_SSH_IDENTITY}"
else
  bad "ssh identity missing: ${AGENT_OPS_SSH_IDENTITY}"
fi

if agent_ops_unlock_ssh; then
  ok "ssh key loaded into agent"
else
  bad "ssh key not loaded"
fi

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o IdentitiesOnly=yes -i "${AGENT_OPS_SSH_IDENTITY}")
if ssh "${SSH_OPTS[@]}" "${AGENT_OPS_SSH_USER}@${AGENT_OPS_SSH_HOST}" "echo ok" >/dev/null 2>&1; then
  ok "ssh BatchMode login"
else
  bad "ssh BatchMode login"
fi

if command -v kubectl >/dev/null 2>&1; then
  ok "kubectl $(kubectl version --client --short 2>/dev/null | tr -d '\n' || kubectl version --client | head -1)"
else
  bad "kubectl not installed"
fi

if kubectl cluster-info --request-timeout=8s >/dev/null 2>&1; then
  ok "kubectl cluster-info ${AGENT_OPS_K8S_API}"
else
  bad "kubectl cannot reach the cluster"
fi

if command -v helm >/dev/null 2>&1; then
  ok "helm $(helm version --short 2>/dev/null || true)"
else
  bad "helm not installed on the Mac workstation"
fi

if [[ -d "${ROOT}/${AGENT_OPS_CHART_DIR}" ]]; then
  ok "chart path ${AGENT_OPS_CHART_DIR}"
else
  warn "chart path missing: ${AGENT_OPS_CHART_DIR} (add a chart before deploy)"
fi

if [[ -f "${ROOT}/${AGENT_OPS_VALUES_FILE}" ]]; then
  ok "local values ${AGENT_OPS_VALUES_FILE}"
else
  warn "local values missing: ${AGENT_OPS_VALUES_FILE}"
fi

if command -v helm >/dev/null 2>&1 && [[ -d "${ROOT}/${AGENT_OPS_CHART_DIR}" ]]; then
  if helm list -n "${AGENT_OPS_NAMESPACE}" >/dev/null 2>&1; then
    RELEASE_LINE="$(helm list -n "${AGENT_OPS_NAMESPACE}" -q | tr '\n' ' ')"
    ok "helm release in ${AGENT_OPS_NAMESPACE}: ${RELEASE_LINE:-none}"
  else
    warn "helm list failed for namespace ${AGENT_OPS_NAMESPACE}"
  fi
fi

if kubectl get nodes >/dev/null 2>&1; then
  NODE_LINE="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status} {.status.nodeInfo.osImage}{end}')"
  ok "node ${NODE_LINE}"
else
  bad "kubectl get nodes"
fi

if kubectl get ns "${AGENT_OPS_NAMESPACE}" >/dev/null 2>&1; then
  ok "namespace ${AGENT_OPS_NAMESPACE}"
  echo
  kubectl get pods -n "${AGENT_OPS_NAMESPACE}" -o wide || true
else
  warn "namespace ${AGENT_OPS_NAMESPACE} missing (created on first helm install)"
fi

echo
echo "Ubuntu host probe via kubectl debug (no SSH required)"
if [[ -x "${ROOT}/scripts/ubuntu-host-probe.sh" ]]; then
  if kubectl get ns "${AGENT_OPS_NAMESPACE}" >/dev/null 2>&1 && "${ROOT}/scripts/ubuntu-host-probe.sh"; then
    ok "host probe"
  else
    warn "host probe skipped or failed (namespace may not exist yet)"
  fi
fi

echo
echo "Development process checklist"
echo "  1. Mac edits source in this workspace"
echo "  2. Put the key passphrase in ~/.config/agent-ops/ssh-passphrase or reuse ~/.config/ragline/ssh-passphrase"
echo "  3. Skip bootstrap on the shared RAGline Ubuntu node (Docker/k3s/registry already exist)"
echo "  4. Clone or sync checkout to ${AGENT_OPS_REMOTE_ROOT}"
echo "  5. ./ssh-ubuntu.sh build <service> [tag]"
echo "  6. ./ssh-ubuntu.sh deploy [tag]   (Helm runs on this Mac)"
echo "  7. ./ssh-ubuntu.sh smoke"
echo

echo "summary pass=${PASS} warn=${WARN} fail=${FAIL}"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
