# shellcheck shell=bash
# One ssh-agent per user, shared by every shell through a fixed socket. A key
# added once (ssh-add, or `AddKeysToAgent yes` in ~/.ssh/config) then works
# in every terminal, including VS Code's, which are not login shells.
#
# An agent that already answers -- forwarded over SSH, or provided by the
# desktop session -- is left alone.

if command -v ssh-agent >/dev/null 2>&1; then
  # ssh-add -l exits 0 (keys) or 1 (no keys) when it reaches an agent, and 2
  # when it can't.
  _ssh_agent_reachable() {
    ssh-add -l >/dev/null 2>&1
    [ $? -ne 2 ]
  }
  if ! _ssh_agent_reachable; then
    export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"
    if ! _ssh_agent_reachable; then
      # Nothing answers on the socket: no agent yet, or a stale socket left
      # by one that died (WSL shutdown, reboot).
      rm -f "$SSH_AUTH_SOCK"
      mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
      eval "$(ssh-agent -s -a "$SSH_AUTH_SOCK")" >/dev/null
    fi
  fi
  unset -f _ssh_agent_reachable
fi
