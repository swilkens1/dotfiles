# shellcheck shell=bash
# Windows PATH whitelist. Assumes MSYS2_PATH_TYPE=strict in msys2.ini, so
# nothing from the inherited Windows PATH leaks in — we add back only what
# we actually use. Idempotent.
_winpath_add() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) [ -d "$1" ] && PATH="$PATH:$1" ;;
  esac
}

case "$OSTYPE" in
  msys*|cygwin*)
    # Windows system essentials
    _winpath_add "/c/Windows/System32"
    _winpath_add "/c/Windows"
    _winpath_add "/c/Windows/System32/Wbem"
    _winpath_add "/c/Windows/System32/WindowsPowerShell/v1.0"
    _winpath_add "/c/Windows/System32/OpenSSH"

    # App execution aliases (winget lives here)
    _winpath_add "$LOCALAPPDATA/Microsoft/WindowsApps"

    # Dev tools installed via winget or their own installers
    _winpath_add "/c/Users/$USER/AppData/Local/Programs/Git/cmd"
    _winpath_add "/c/Users/$USER/AppData/Local/Programs/Microsoft VS Code/bin"
    _winpath_add "/c/Program Files/Amazon/AWSCLIV2"
    _winpath_add "/c/Program Files/Amazon/SessionManagerPlugin/bin"
    _winpath_add "/c/Program Files/Docker/Docker/resources/bin"
    _winpath_add "/c/Program Files/Multipass/bin"
    _winpath_add "/c/Users/$USER/AppData/Local/Python/bin"

    export PATH
    ;;
esac

# MSYS/Cygwin path-mangling workarounds for tools that take container/k8s paths.
# Without MSYS_NO_PATHCONV=1, MSYS/Git-Bash rewrites args like /etc/passwd into
# C:/Program Files/Git/etc/passwd before the binary sees them.

docker() {
  case "$OSTYPE" in
    msys*|cygwin*) MSYS_NO_PATHCONV=1 command docker "$@" ;;
    *)             command docker "$@" ;;
  esac
}

kubectl() {
  case "$OSTYPE" in
    msys*|cygwin*) MSYS_NO_PATHCONV=1 command kubectl "$@" ;;
    *)             command kubectl "$@" ;;
  esac
}

# Skopeo via container — mounts cwd and docker creds read-only. If a corp CA
# bundle is exported via AWS_CA_BUNDLE (see 30-aws.sh, which sources it from
# CORP_CA_BUNDLE or ~/.aws/corp-ca.cer), mount that too so skopeo can reach
# corp-MITM'd registries.
skopeo() {
  touch "$HOME/.skopeo-auth.json"
  chmod 600 "$HOME/.skopeo-auth.json"
  local ca_arg=""
  if [ -n "${AWS_CA_BUNDLE:-}" ] && [ -f "$AWS_CA_BUNDLE" ]; then
    ca_arg="-v /$AWS_CA_BUNDLE://etc/ssl/certs/ca-certificates.crt:ro"
  fi
  docker run --rm -i \
    -v "/$(pwd)://workspace" \
    -v "/$HOME/.docker://root/.docker:ro" \
    $ca_arg \
    -w //workspace \
    quay.io/skopeo/stable:latest "$@"
}
export -f skopeo
