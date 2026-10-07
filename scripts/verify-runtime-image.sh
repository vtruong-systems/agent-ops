#!/usr/bin/env bash
# Verify the fixture suite both inside a runtime image and over its HTTP API.

set -euo pipefail

IMAGE="${1:-}"
if [[ -z "${IMAGE}" ]]; then
  echo "usage: $0 <runtime-image>"
  exit 1
fi

SUFFIX="${RANDOM}-$$"
NETWORK="agent-ops-verify-${SUFFIX}"
SERVER="agent-ops-runtime-verify-${SUFFIX}"

cleanup() {
  docker rm -f "${SERVER}" >/dev/null 2>&1 || true
  docker network rm "${NETWORK}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "verifying fixture eval inside ${IMAGE}"
docker run --rm "${IMAGE}" \
  python -m agent_ops.eval --provider fake --report /tmp/eval-report.json

docker network create "${NETWORK}" >/dev/null
docker run -d --name "${SERVER}" --network "${NETWORK}" "${IMAGE}" >/dev/null

echo "verifying fixture eval against ${IMAGE} over HTTP"
docker run --rm --network "${NETWORK}" "${IMAGE}" \
  python -m agent_ops.eval \
    --provider fake \
    --target "http://${SERVER}:8080" \
    --report /tmp/eval-report-http.json

echo "verified ${IMAGE}"
