# If not running interactively, don't do anything
[[ "$-" != *i* ]] && return

set -o vi
# Terminals that report plain "xterm" (Git Bash's mintty, some SSH clients)
# do 256 colors. Anything else -- tmux-256color inside tmux, screen -- knows
# its own TERM and must keep it.
if [ "$TERM" = xterm ]; then
  export TERM=xterm-256color
fi

# Source modular config in lexicographic order: 10-* before 20-*, etc.
# Use multiples of 10 so new modules can slot in between (15-foo.sh)
# without renaming neighbors.
if [ -d "$HOME/.bashrc.d" ]; then
  for rc in "$HOME"/.bashrc.d/*.sh; do
    [ -r "$rc" ] && . "$rc"
  done
  unset rc
fi

# Read by ~/.bash_profile. Not exported, so child shells still load .bashrc,
# and a manual `. ~/.bashrc` still reloads everything.
_DOTFILES_BASHRC_LOADED=1
