# shellcheck shell=bash
# Corporate CA bundle. Set CORP_CA_BUNDLE in a local-only ~/.bashrc.d/9*.sh
# to point at your machine's cert, OR drop the cert at the default location
# and this picks it up automatically. Extract with ~/extract-corp-ca.sh
# (works from Git Bash or MSYS2). Guarded so a machine without a corp CA
# doesn't export a bogus path that would error every aws call.
CORP_CA_BUNDLE="${CORP_CA_BUNDLE:-$HOME/.local/share/corp-ca.cer}"
if [ -f "$CORP_CA_BUNDLE" ]; then
  export AWS_CA_BUNDLE="$CORP_CA_BUNDLE"
fi
unset CORP_CA_BUNDLE

# List configured AWS profiles from config + credentials.
_aws_profiles() {
  cat ~/.aws/config ~/.aws/credentials 2>/dev/null \
    | sed -n 's#^\[\(profile \)\?\(.*\)\]#\2#p' \
    | tr -d '\r' \
    | sort -u
}

_getprofiles() {
  COMPREPLY=($(compgen -W "$(_aws_profiles)" -- "${COMP_WORDS[1]}"))
}

# AWS profile switcher.  `aps` shows current, `aps -l` lists, `aps NAME` switches.
aps() {
  case "$1" in
    "")        echo "AWS profile is ${AWS_PROFILE:-unset}" ;;
    -l|--list) _aws_profiles ;;
    *)
      if _aws_profiles | grep -qx "$1"; then
        export AWS_PROFILE="$1"
      else
        echo "Profile '$1' not found"
        return 1
      fi
      ;;
  esac
}
complete -F _getprofiles aps

# aws CLI subcommand completion. On Windows the completer is a bundled .exe
# from the AWSCLIV2 install and needs a CRLF->LF bridge; on Linux/macOS it's
# on PATH and wire-compatible with bash's `complete -C`.
case "$OSTYPE" in
  msys*|cygwin*)
    _AWS_COMPLETER="/c/Program Files/Amazon/AWSCLIV2/aws_completer"
    if [ -x "$_AWS_COMPLETER" ]; then
      _aws_completer_wrapper() {
        local compline="${COMP_LINE}" comppoint="${COMP_POINT}"
        export COMP_LINE="${compline}" COMP_POINT="${comppoint}"
        IFS=$'\n' COMPREPLY=($( "$_AWS_COMPLETER" | dos2unix ))
      }
      complete -F _aws_completer_wrapper aws
    fi
    unset _AWS_COMPLETER
    ;;
  *)
    if command -v aws_completer >/dev/null 2>&1; then
      complete -C aws_completer aws
    fi
    ;;
esac
