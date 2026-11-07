test -f ~/.profile && . ~/.profile
# Ubuntu's stock ~/.profile already sources ~/.bashrc; don't load it twice.
if [ -z "${_DOTFILES_BASHRC_LOADED:-}" ]; then
  test -f ~/.bashrc && . ~/.bashrc
fi
