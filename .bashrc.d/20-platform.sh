# shellcheck shell=bash
# Cross-platform PATH additions, XDG dirs, native-tool config redirects,
# and MSYS/Cygwin path-mangling workarounds.
#
# Git Bash on Windows inherits the full Windows PATH by default, so
# system dirs (System32, git\cmd, VS Code) are already there. We add
# only tool-manager shim locations that aren't inherited.

_path_add() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) [ -d "$1" ] && PATH="$PATH:$1" ;;
  esac
}

case "$OSTYPE" in
  msys*|cygwin*)
    # Scoop installs under $SCOOP if set, else %USERPROFILE%\scoop -- which is
    # NOT $HOME here, since HOME is relocated to C:\DevOpsHome. Resolve in
    # Windows form, then cygpath to a POSIX path (same approach as 60-mise.sh).
    # Global installs (scoop install -g) live under $SCOOP_GLOBAL or
    # %ProgramData%\scoop and get their own shims dir.
    _scoop_win="${SCOOP:-${USERPROFILE:-$HOME}/scoop}"
    _scoop_shims=$(cygpath -u "$_scoop_win/shims" 2>/dev/null) ||
      _scoop_shims="$_scoop_win/shims"
    _path_add "$_scoop_shims"

    _scoop_gwin="${SCOOP_GLOBAL:-${ProgramData:-${ALLUSERSPROFILE:-}}/scoop}"
    _scoop_gshims=$(cygpath -u "$_scoop_gwin/shims" 2>/dev/null) ||
      _scoop_gshims="$_scoop_gwin/shims"
    _path_add "$_scoop_gshims"

    unset _scoop_win _scoop_shims _scoop_gwin _scoop_gshims
    export PATH

    # Redirect Windows-native tool config to $HOME so a moved HOME
    # (e.g., C:\DevOpsHome) actually holds the config. Each env var
    # here is a native-tool escape hatch that avoids needing a junction.
    # Junctioned by bootstrap.sh: .aws, .claude, .ssh -- none of those
    # have a reliable env-var override.
    export DOCKER_CONFIG="$HOME/.docker"
    export KUBECONFIG="$HOME/.kube/config"
    ;;
  linux*)
    # linuxbrew installs under /home/linuxbrew/.linuxbrew.
    if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
      eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    fi
    ;;
  darwin*)
    # Apple Silicon: /opt/homebrew. Intel: /usr/local.
    if [ -x /opt/homebrew/bin/brew ]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
    ;;
esac

# XDG base-dir defaults made explicit so tools that read them use
# $HOME-anchored paths. Matters when $HOME != %USERPROFILE% on Windows;
# also codifies the standard defaults on Linux/macOS.
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

# MSYS/Cygwin path-mangling workarounds for tools that take container/k8s
# paths. Without MSYS_NO_PATHCONV=1, Git Bash rewrites args like
# /etc/passwd into C:/Program Files/Git/etc/passwd before the binary
# sees them.

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

# Skopeo via container -- mounts cwd and docker creds read-only. If a
# corp CA bundle is exported via AWS_CA_BUNDLE (see 30-aws.sh, which
# sources it from CORP_CA_BUNDLE or ~/.aws/corp-ca.cer), mount that
# too so skopeo can reach corp-MITM'd registries.
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
