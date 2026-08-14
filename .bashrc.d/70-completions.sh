# shellcheck shell=bash
# Programmable completion: the bash-completion library plus per-tool scripts.
#
# Git Bash ships no bash-completion package (no /usr/share/bash-completion,
# no /etc/bash_completion.d) -- it bundles only git's own completions. The
# library is a single pure-bash file with no build step, installed to
# $XDG_DATA_HOME/bash-completion/bash_completion by hand.
#
# Loads last (70-) so PATH is fully assembled by 20-platform.sh (scoop shims)
# and 60-mise.sh (mise shims) before any `command -v` probe runs here.

_bc="$XDG_DATA_HOME/bash-completion/bash_completion"
if [ -r "$_bc" ]; then
  # shellcheck disable=SC1090
  . "$_bc"

  # bash-completion 2.12 renamed its public helpers (_init_completion ->
  # _comp_initialize, etc.) and 2.16 removed the old names entirely -- there
  # are zero references to them left in the library. Cobra-generated scripts
  # (kubectl, gh, helm) still emit the pre-2.12 names, so without these three
  # aliases every <TAB> dies with `_get_comp_words_by_ref: command not found`.
  # _comp_deprecate_func is the library's own supported shim mechanism.
  if declare -F _comp_deprecate_func >/dev/null 2>&1; then
    declare -F _comp_get_words >/dev/null 2>&1 &&
      _comp_deprecate_func 2.12 _get_comp_words_by_ref _comp_get_words
    declare -F _comp_initialize >/dev/null 2>&1 &&
      _comp_deprecate_func 2.12 _init_completion _comp_initialize
    declare -F _comp_ltrim_colon_completions >/dev/null 2>&1 &&
      _comp_deprecate_func 2.12 __ltrim_colon_completions _comp_ltrim_colon_completions
  fi
fi
unset _bc

# Per-tool completion scripts, cached. `<tool> completion bash` shells out to
# the tool itself, which costs ~0.5-1s per tool on Windows -- far too slow to
# run on every shell start. Cache is regenerated when the tool binary is newer
# than the cached script, so a scoop/mise upgrade refreshes it automatically.
_comp_cache="$XDG_CACHE_HOME/bash_completion.d"
[ -d "$_comp_cache" ] || mkdir -p "$_comp_cache"

_comp_load() {
  local tool="$1"; shift
  local bin cache
  # `type -P` and not `command -v`: kubectl and docker are wrapper *functions*
  # (20-platform.sh), so command -v returns the function name rather than a
  # path, and the -nt freshness check below would silently never fire.
  bin=$(type -P "$tool" 2>/dev/null) || return 0
  [ -n "$bin" ] || return 0
  cache="$_comp_cache/$tool.bash"
  if [ ! -s "$cache" ] || [ "$bin" -nt "$cache" ]; then
    "$tool" "$@" >"$cache" 2>/dev/null || { rm -f "$cache"; return 0; }
  fi
  # shellcheck disable=SC1090
  . "$cache" 2>/dev/null || return 0
}

_comp_load kubectl completion bash
_comp_load docker completion bash
_comp_load gh completion -s bash
_comp_load helm completion bash

# mise emits only a thin dispatcher that calls the separate `usage` CLI at
# completion time; without it on PATH every <TAB> prints an error instead of
# completing. Install with: mise use -g usage
if command -v usage >/dev/null 2>&1; then
  _comp_load mise completion bash
fi

unset _comp_cache
