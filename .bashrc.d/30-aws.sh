# shellcheck shell=bash
# AWS CLI: pager, profile switching (aps), command builder (awsi), help
# search (awshelp), completion. The corporate CA comes from 25-ca.sh.

# The CLI pages `help` and long output through this. -i gives case-insensitive
# `/` search inside the docs, -R keeps color.
if command -v less >/dev/null 2>&1; then
  export AWS_PAGER='less -R -i'
fi

# List configured AWS profiles, from the same files the CLI reads. In the
# config file only [default] and [profile NAME] are profiles -- not
# [sso-session ...] or [services ...]; in credentials every section is.
_aws_profiles() {
  local config="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
  local creds="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
  local files=() f
  for f in "$config" "$creds"; do [ -r "$f" ] && files+=("$f"); done
  [ ${#files[@]} -gt 0 ] || return 0
  awk -v creds="$creds" '
    { sub(/\r$/, "") }
    /^[[:space:]]*\[/ {
      s = $0
      gsub(/^[[:space:]]*\[[[:space:]]*|[[:space:]]*\][[:space:]]*$/, "", s)
      if (FILENAME == creds) print s
      else if (s == "default") print s
      else if (sub(/^profile[[:space:]]+/, "", s)) print s
    }' "${files[@]}" | sort -u
}

_getprofiles() {
  mapfile -t COMPREPLY < <(compgen -W "$(_aws_profiles)" -- "${COMP_WORDS[1]}")
}

# AWS profile switcher; see `aps -h`.
aps() {
  case "${1:-}" in
    -h|--help)
      cat <<'EOF'
Usage: aps [PROFILE | -l | -u | -h]
  aps            show the current profile (AWS_PROFILE)
  aps PROFILE    switch this shell to PROFILE (tab completes)
  aps -l         list profiles from ~/.aws/config and ~/.aws/credentials
  aps -u         unset AWS_PROFILE (back to the default profile)
  aps -h         show this help
EOF
      ;;
    "")         echo "AWS profile is ${AWS_PROFILE:-unset}" ;;
    -l|--list)  _aws_profiles ;;
    -u|--unset) unset AWS_PROFILE ;;
    -*)         echo "aps: unknown option $1 (see aps -h)" >&2; return 1 ;;
    *)
      if _aws_profiles | grep -qxF -- "$1"; then
        export AWS_PROFILE="$1"
      else
        echo "aps: profile '$1' not found (aps -l lists them)" >&2
        return 1
      fi
      ;;
  esac
}
complete -F _getprofiles aps

# Interactive command builder: fuzzy subcommand search with inline parameter
# docs.
#
# On Windows it needs a real console: prompt_toolkit rejects mintty with
# "Found xterm-256color, while expecting a Windows console".
awsi() {
  case "$OSTYPE" in
    msys*|cygwin*) winpty aws --cli-auto-prompt "$@" ;;
    *)             aws --cli-auto-prompt "$@" ;;
  esac
}

# Jump to the Examples section of any command's built-in docs
# Ex:  awshelp ec2 describe-instances
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
# from the AWSCLIV2 install and needs a CRLF->LF bridge
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
        # One candidate per line; mapfile also keeps candidates from being
        # glob-expanded, which word-splitting a $(...) would do.
        mapfile -t COMPREPLY < <(
          COMP_LINE="$COMP_LINE" COMP_POINT="$COMP_POINT" \
            "$_AWS_COMPLETER" 2>/dev/null | tr -d '\r'
        )
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
