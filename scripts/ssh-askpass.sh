#!/usr/bin/env bash
# Prints the SSH key passphrase for OpenSSH SSH_ASKPASS. stdout must be only
# the passphrase. Do not log, echo extras, or write this value into git.

set -euo pipefail

if [[ -n "${AGENT_OPS_SSH_PASSPHRASE:-}" ]]; then
  printf '%s\n' "${AGENT_OPS_SSH_PASSPHRASE}"
  exit 0
fi

file="${AGENT_OPS_SSH_PASSPHRASE_FILE:-}"
if [[ -z "${file}" ]]; then
  exit 1
fi
if [[ ! -f "${file}" ]]; then
  exit 1
fi

IFS= read -r line < "${file}" || true
printf '%s\n' "${line}"
