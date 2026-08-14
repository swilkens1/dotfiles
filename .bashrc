# If not running interactively, don't do anything
[[ "$-" != *i* ]] && return

set -o vi
export TERM=xterm-256color

# Source modular config in lexicographic order: 10-* before 20-*, etc.
# Use multiples of 10 so new modules can slot in between (15-foo.sh)
# without renaming neighbors.
if [ -d "$HOME/.bashrc.d" ]; then
  for rc in "$HOME"/.bashrc.d/*.sh; do
    [ -r "$rc" ] && . "$rc"
  done
  unset rc
fi

. "$HOME/.local/share/../bin/env"
