# shellcheck shell=bash
# Point tools that ignore the OS trust store at a bundle that includes the
# corporate CA: the AWS CLI (ships its own CA list), Python requests, Node.
#
# Linux/WSL: the system bundle already holds the corporate CA once it is
# installed (sync-windows-ca on WSL, ca-add elsewhere), so use that -- but
# only when local CAs exist, leaving stock machines untouched.
# Git Bash: there is no system store to extend; use the PEM written by
# extract-corp-ca, for the AWS CLI only (it is the corporate cert alone, not
# a full bundle, so it can't replace Python's or Node's).
#
# Override with CORP_CA_BUNDLE in a local ~/.bashrc.d/00-*.sh, which loads
# before this file.

case "$OSTYPE" in
  msys*|cygwin*)
    _ca="${CORP_CA_BUNDLE:-$HOME/.local/share/corp-ca.cer}"
    if [ -f "$_ca" ]; then
      export AWS_CA_BUNDLE="$_ca"
    fi
    ;;
  *)
    _ca="${CORP_CA_BUNDLE:-}"
    if [ -z "$_ca" ] && [ -f /etc/ssl/certs/ca-certificates.crt ] &&
       [ -n "$(find /usr/local/share/ca-certificates -name '*.crt' -print -quit 2>/dev/null)" ]; then
      _ca=/etc/ssl/certs/ca-certificates.crt
    fi
    if [ -n "$_ca" ] && [ -f "$_ca" ]; then
      export AWS_CA_BUNDLE="$_ca" REQUESTS_CA_BUNDLE="$_ca" NODE_EXTRA_CA_CERTS="$_ca"
    fi
    ;;
esac
unset _ca
