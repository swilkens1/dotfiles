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

# The CLI pages `help` and long output through this. -i gives case-insensitive
# `/` search inside the docs, -R keeps color. Piped output bypasses the pager
# automatically, so this only affects interactive reading.
if command -v less >/dev/null 2>&1; then
  export AWS_PAGER='less -R -i'
fi

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

# Interactive command builder: fuzzy subcommand search with inline parameter
# docs. Deliberately a separate command rather than AWS_CLI_AUTO_PROMPT in the
# environment -- that variable is read by *every* aws invocation, including the
# scripted ones in 40-ssm.sh, which would then hit the console error below
# instead of failing cleanly.
#
# On Windows it needs a real console: prompt_toolkit rejects mintty with
# "Found xterm-256color, while expecting a Windows console". winpty bridges it.
awsi() {
  case "$OSTYPE" in
    msys*|cygwin*) winpty aws --cli-auto-prompt "$@" ;;
    *)             aws --cli-auto-prompt "$@" ;;
  esac
}

# Jump to the Examples section of any command's built-in docs, which is the
# part worth reading. `aws ec2 describe-instances help` is ~5600 lines; the
# Output section documents the response shape you need for --query.
#   awshelp ec2 describe-instances
awshelp() {
  [ $# -gt 0 ] || { echo "usage: awshelp <service> [command]" >&2; return 1; }
  local pat="${AWSHELP_SECTION:-^Examples}" doc grep_cmd
  grep_cmd=$(command -v rg || command -v grep) || return 1
  doc=$(aws "$@" help 2>/dev/null) || return 1
  if printf '%s\n' "$doc" | "$grep_cmd" -q "$pat"; then
    printf '%s\n' "$doc" | "$grep_cmd" -A60 "$pat"
  else
    printf '%s\n' "$doc"
  fi
}

# aws CLI subcommand completion. On Windows the completer is a bundled .exe
# from the AWSCLIV2 install and needs a CRLF->LF bridge; on Linux/macOS it's
# on PATH and wire-compatible with bash's `complete -C`.
case "$OSTYPE" in
  msys*|cygwin*)
    # Stays global on purpose: `complete -F` expands the function body at
    # completion time, not now, so unsetting this after registering leaves
    # the wrapper invoking "" -- which is the `bash: : command not found`
    # you get on every <TAB>.
    _AWS_COMPLETER="$(command -v aws_completer 2>/dev/null)"
    [ -n "$_AWS_COMPLETER" ] ||
      _AWS_COMPLETER="/c/Program Files/Amazon/AWSCLIV2/aws_completer"
    if [ -x "$_AWS_COMPLETER" ]; then
      _aws_completer_wrapper() {
        # `local` matters: a bare IFS=$'\n' here is a plain assignment, not a
        # command prefix, so it would clobber IFS for the whole shell.
        local IFS=$'\n'
        COMPREPLY=( $(
          COMP_LINE="$COMP_LINE" COMP_POINT="$COMP_POINT" \
            "$_AWS_COMPLETER" 2>/dev/null | tr -d '\r'
        ) )
      }
      complete -F _aws_completer_wrapper aws
    else
      unset _AWS_COMPLETER
    fi
    ;;
  *)
    if command -v aws_completer >/dev/null 2>&1; then
      complete -C aws_completer aws
    fi
    ;;
esac
