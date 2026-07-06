# Dotfiles bare-repo helpers.
#
# The repo lives at ~/.cfg with the work-tree set to $HOME.
# `info/exclude` contains `*` so nothing shows up untracked by accident —
# you must use `config add -f <path>` to start tracking a new file.

alias config='git --git-dir=$HOME/.cfg/ --work-tree=$HOME'

dotsync() {
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

  read -p "Enter commit message (or press Enter for 'Auto-update'): " msg
  if [ -z "$msg" ]; then
    msg="Auto-update $(date '+%Y-%m-%d %H:%M')"
  fi

  config add -u
  config commit -m "$msg"
  config push
}
