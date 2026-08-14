# shellcheck shell=bash
# Dotfiles bare-repo helpers.
#
# The repo lives at ~/.cfg with the work-tree set to $HOME.
# `info/exclude` contains `*` so nothing shows up untracked by accident —
# you must use `config add -f <path>` to start tracking a new file.

alias config='git --git-dir=$HOME/.cfg/ --work-tree=$HOME'

# dotsync            -- opens $EDITOR (core.editor = vim) prefilled with the
#                       Auto-update line, so :wq keeps the old behaviour and
#                       you can instead write a subject + blank line + body.
#                       Clearing the buffer entirely aborts the commit.
# dotsync -m "msg"   -- skip the editor for a quick one-liner.
dotsync() {
  local msg=""
  if [ "${1:-}" = "-m" ]; then
    if [ -z "${2:-}" ]; then
      echo "Error: -m requires a message." >&2
      return 1
    fi
    msg="$2"
  fi

  echo "Checking for remote updates..."
  if ! config pull; then
    echo "Error: Pull failed. Resolve conflicts manually before syncing."
    return 1
  fi

  if config diff --quiet && config diff --cached --quiet; then
    echo "No changes detected in tracked dotfiles."
    return 0
  fi

  echo "--- Current Changes ---"
  config status -s
  echo "-----------------------"

  config add -u

  # `read` can only ever produce a single line, which is why the old prompt
  # could not write a commit body. `commit -e -m` hands the message to the
  # editor instead: -m seeds the buffer, -e forces the editor open even
  # though -m was given.
  if [ -n "$msg" ]; then
    config commit -m "$msg" || { echo "Commit aborted; changes stay staged."; return 1; }
  else
    config commit -e -m "Auto-update $(date '+%Y-%m-%d %H:%M')" ||
      { echo "Commit aborted; changes stay staged."; return 1; }
  fi
  config push
}
