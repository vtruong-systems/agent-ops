#!/usr/bin/env bash
# Load ~/.ssh/mac-ubuntu (or AGENT_OPS_SSH_IDENTITY) into ssh-agent using a
# local passphrase file. Source this file; do not execute it.
#
# Passphrase lookup order:
#   1. AGENT_OPS_SSH_PASSPHRASE
#   2. AGENT_OPS_SSH_PASSPHRASE_FILE
#   3. $HOME/.config/agent-ops/ssh-passphrase
#   4. $HOME/.config/ragline/ssh-passphrase (same Ubuntu host as RAGline)
#   5. <workspace>/scripts/.ssh-passphrase
#
# Do not put the passphrase in a tracked script.

agent_ops_passphrase_file() {
  if [[ -n "${AGENT_OPS_SSH_PASSPHRASE_FILE:-}" ]]; then
    printf '%s\n' "${AGENT_OPS_SSH_PASSPHRASE_FILE}"
    return
  fi
  if [[ -f "${HOME}/.config/agent-ops/ssh-passphrase" ]]; then
    printf '%s\n' "${HOME}/.config/agent-ops/ssh-passphrase"
    return
  fi
  if [[ -f "${HOME}/.config/ragline/ssh-passphrase" ]]; then
    printf '%s\n' "${HOME}/.config/ragline/ssh-passphrase"
    return
  fi
  if [[ -n "${ROOT:-}" && -f "${ROOT}/scripts/.ssh-passphrase" ]]; then
    printf '%s\n' "${ROOT}/scripts/.ssh-passphrase"
    return
  fi
}

agent_ops_identity_in_agent() {
  local pub fp
  pub="${AGENT_OPS_SSH_IDENTITY}.pub"
  if [[ ! -f "${pub}" ]]; then
    return 1
  fi
  fp="$(ssh-keygen -lf "${pub}" 2>/dev/null | awk '{print $2}')"
  if [[ -z "${fp}" ]]; then
    return 1
  fi
  ssh-add -l 2>/dev/null | grep -q "${fp}"
}

agent_ops_unlock_ssh() {
  if agent_ops_identity_in_agent; then
    return 0
  fi

  local file askpass
  file="$(agent_ops_passphrase_file || true)"
  askpass="${ROOT}/scripts/ssh-askpass.sh"

  if [[ -z "${AGENT_OPS_SSH_PASSPHRASE:-}" && ( -z "${file}" || ! -f "${file}" ) ]]; then
    echo "SSH key is locked and no local passphrase file was found."
    echo "Create one of these, mode 600, containing only the passphrase:"
    echo "  ${HOME}/.config/agent-ops/ssh-passphrase"
    echo "  ${HOME}/.config/ragline/ssh-passphrase"
    echo "  ${ROOT}/scripts/.ssh-passphrase"
    echo "Or copy scripts/.ssh-passphrase.example to scripts/.ssh-passphrase"
    return 1
  fi

  if [[ -n "${file}" && -f "${file}" ]]; then
    chmod 600 "${file}" 2>/dev/null || true
    export AGENT_OPS_SSH_PASSPHRASE_FILE="${file}"
  fi

  export SSH_ASKPASS="${askpass}"
  export SSH_ASKPASS_REQUIRE=force
  export DISPLAY="${DISPLAY:-ssh-askpass}"

  if ! SSH_ASKPASS="${askpass}" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY}" \
    ssh-add --apple-use-keychain "${AGENT_OPS_SSH_IDENTITY}" </dev/null >/dev/null 2>&1; then
    echo "ssh-add failed. Check the passphrase file and identity ${AGENT_OPS_SSH_IDENTITY}"
    return 1
  fi

  agent_ops_identity_in_agent
}
