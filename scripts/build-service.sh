#!/usr/bin/env bash
# Build one service image on the Ubuntu host.
# Usage: ./scripts/build-service.sh <service-name> [tag]
#
# Expects services/<name>/Dockerfile. Context is the service directory unless
# AGENT_OPS_BUILD_CONTEXT=repo is set (repository root, -f Dockerfile).

set -euo pipefail

SERVICE="${1:-}"
TAG="${2:-latest}"

if [[ -z "${SERVICE}" ]]; then
  echo "usage: $0 <service-name> [tag]"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVICE_DIR="${REPO_ROOT}/services/${SERVICE}"
PREFIX="${AGENT_OPS_IMAGE_PREFIX:-agent-ops}"

if [[ ! -d "${SERVICE_DIR}" ]]; then
  echo "service directory not found: ${SERVICE_DIR}"
  exit 1
fi
if [[ ! -f "${SERVICE_DIR}/Dockerfile" ]]; then
  echo "Dockerfile not found: ${SERVICE_DIR}/Dockerfile"
  exit 1
fi

if [[ -z "${AGENT_OPS_BUILD_CONTEXT:-}" && -f "${SERVICE_DIR}/build.env" ]]; then
  # shellcheck disable=SC1091
  source "${SERVICE_DIR}/build.env"
fi

BUILD_ARGS=(--platform "${AGENT_OPS_DOCKER_PLATFORM:-linux/amd64}")
if [[ "${AGENT_OPS_DOCKER_NO_CACHE:-0}" == "1" ]]; then
  BUILD_ARGS+=(--no-cache)
fi
if [[ -n "${AGENT_OPS_DOCKER_NETWORK:-}" ]]; then
  BUILD_ARGS+=(--network "${AGENT_OPS_DOCKER_NETWORK}")
fi

IMAGE="${PREFIX}-${SERVICE}:${TAG}"
echo "building ${IMAGE} as linux/amd64"

if [[ "${AGENT_OPS_BUILD_CONTEXT:-service}" == "repo" ]]; then
  docker build "${BUILD_ARGS[@]}" -t "${IMAGE}" -f "${SERVICE_DIR}/Dockerfile" "${REPO_ROOT}"
else
  docker build "${BUILD_ARGS[@]}" -t "${IMAGE}" "${SERVICE_DIR}"
fi

echo "built ${IMAGE}"

if [[ "${SERVICE}" == "runtime" ]]; then
  "${REPO_ROOT}/scripts/verify-runtime-image.sh" "${IMAGE}"
fi
