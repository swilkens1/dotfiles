test -f ~/.profile && . ~/.profile
# Ubuntu's stock ~/.profile already sources ~/.bashrc; don't load it twice.
if [ -z "${_DOTFILES_BASHRC_LOADED:-}" ]; then
  test -f ~/.bashrc && . ~/.bashrc
fi

# Check if ssh-agent is already running under your user
if ! ps -ef | grep -v "grep" | grep -q "ssh-agent"; then
    eval $(ssh-agent -s)
fi
