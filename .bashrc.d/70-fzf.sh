# shellcheck shell=bash
# fzf key bindings -- Ctrl-R history, Ctrl-T files, Alt-C cd -- and `**<TAB>`
# completion (--with=cli). Loads after 70-completions.sh, so fzf's completion
# wraps the bash-completion ones. `fzf --bash` needs fzf 0.48+; older ones
# print nothing here and are skipped.

if command -v fzf >/dev/null 2>&1; then
  eval "$(fzf --bash 2>/dev/null)"
fi
