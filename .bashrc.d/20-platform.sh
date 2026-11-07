# shellcheck shell=bash
# XDG dirs everywhere; on Git Bash also tool-manager PATH entries, native-
# tool config redirects, and MSYS path-mangling workarounds.

_path_add() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) [ -d "$1" ] && PATH="$PATH:$1" ;;
  esac
}

# XDG base-dir defaults made explicit so tools that read them use
# $HOME-anchored paths. Matters when $HOME != %USERPROFILE% on Windows;
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

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
    # Junctioned by bootstrap.sh: .aws, .ssh -- neither has a reliable
    # env-var override.
    export DOCKER_CONFIG="$HOME/.docker"
    export KUBECONFIG="$HOME/.kube/config"

    # MSYS path-mangling workarounds for tools that take container/k8s
    # paths. Without MSYS_NO_PATHCONV=1, Git Bash rewrites args like
    # /etc/passwd into C:/Program Files/Git/etc/passwd before the binary
    # sees them.
    docker()  { MSYS_NO_PATHCONV=1 command docker "$@"; }
    kubectl() { MSYS_NO_PATHCONV=1 command kubectl "$@"; }

    # Windows has no native skopeo, so run it in a container. Mounts cwd
    # and docker creds read-only, plus the corp CA bundle when 25-ca.sh
    # exported one, so corp-MITM'd registries work. (Linux uses apt's
    # skopeo, which reads the system trust store.)
    skopeo() {
      local args=(--rm -i -v "/$(pwd)://workspace" -v "/$HOME/.docker://root/.docker:ro")
      if [ -n "${AWS_CA_BUNDLE:-}" ] && [ -f "$AWS_CA_BUNDLE" ]; then
        args+=(-v "/$AWS_CA_BUNDLE://etc/ssl/certs/ca-certificates.crt:ro")
      fi
      docker run "${args[@]}" -w //workspace quay.io/skopeo/stable:latest "$@"
    }
    ;;
esac
