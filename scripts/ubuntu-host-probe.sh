#!/usr/bin/env bash
# Probe the Ubuntu k3s node filesystem without SSH, using a cached node-debug image.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/dev-env.env"

NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
NS="${AGENT_OPS_NAMESPACE}"
REMOTE_ROOT="${AGENT_OPS_REMOTE_ROOT}"

cleanup() {
  local pod
  while IFS= read -r pod; do
    [[ -z "${pod}" ]] && continue
    kubectl delete pod -n "${NS}" --wait=false --ignore-not-found=true "${pod}" >/dev/null 2>&1 || true
  done < <(kubectl get pods -n "${NS}" --no-headers 2>/dev/null | awk '/^node-debugger-/ {print $1}')
}
trap cleanup EXIT

cleanup

kubectl debug "node/${NODE}" \
  --image="${AGENT_OPS_PROBE_IMAGE}" \
  --profile=general \
  --quiet \
  -- chroot /host /bin/bash -lc "
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
echo HOST=\$(hostname)
echo KERNEL=\$(uname -r)
echo ARCH=\$(uname -m)
echo ---tools---
for b in docker nerdctl buildah git helm kubectl k3s ctr; do
  if command -v \"\$b\" >/dev/null 2>&1; then
    echo \"\$b=\$(command -v \$b)\"
  else
    echo \"\$b=MISSING\"
  fi
done
echo ---k3s---
k3s --version 2>/dev/null | head -1 || true
echo ---registry.yaml---
if [ -f /etc/rancher/k3s/registries.yaml ]; then
  cat /etc/rancher/k3s/registries.yaml
else
  echo MISSING
fi
echo ---listen---
ss -lntp 2>/dev/null | grep -E ':22 |:6443|:5000|:8000' || true
echo ---checkout---
ls -ld ${REMOTE_ROOT} /home/van/src/agent-ops /home/van/src/ragline 2>/dev/null || echo no checkout
echo ---git-dirs---
find /home/van /opt /srv -maxdepth 5 -type d -name .git 2>/dev/null | head -20 || true
echo ---local-registry-images---
k3s ctr images ls 2>/dev/null | awk '{print \$1}' | grep -E 'localhost:5000|agent-ops' | head -30 || true
echo ---ssh-key---
ssh-keygen -lf /home/van/.ssh/authorized_keys 2>/dev/null || echo no authorized_keys
echo ---resources---
free -h | head -2
df -h / | tail -1
"

sleep 2
POD="$(kubectl get pods -n "${NS}" --no-headers | awk '/^node-debugger-/ {print $1; exit}')"
if [[ -z "${POD}" ]]; then
  echo "node debug pod did not appear in namespace ${NS}" >&2
  echo "create the namespace first or run: kubectl create ns ${NS}" >&2
  exit 1
fi
kubectl logs -n "${NS}" "${POD}"
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/"${POD}" -n "${NS}" --timeout=30s >/dev/null 2>&1 || true
