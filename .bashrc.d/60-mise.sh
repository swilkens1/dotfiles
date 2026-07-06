# mise — runtime/tool version manager. Reads ~/.config/mise/config.toml for
# globals and the nearest .tool-versions / mise.toml when you cd into a repo.
# Installed by bootstrap.sh into ~/.local/bin (mise.exe on Windows, mise on
# Linux).
#
# Linux/macOS: `mise activate` injects current tool paths into PATH on each
# prompt — preferred mode.
# Windows (Git Bash): `mise activate bash` emits Windows-format PATH
# (';'-separated, C:\ paths) that bash can't parse, so we fall back to shim
# mode and just put the shims dir on PATH. Each shim is a copy of
# mise-shim.exe that dispatches to the right version at exec time.

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

if command -v mise >/dev/null 2>&1; then
  case "$OSTYPE" in
    msys*|cygwin*)
      # mise's data dir on Windows defaults to %LOCALAPPDATA%\mise (overridable
      # via MISE_DATA_DIR). Shims live in <data>/shims as one .exe per tool.
      # Hard-coding the path because `mise dirs` is broken in 2026.6.11.
      _mise_data="${MISE_DATA_DIR:-$LOCALAPPDATA/mise}"
      _mise_shims=$(cygpath -u "$_mise_data/shims" 2>/dev/null || printf '%s' "$_mise_data/shims")
      if [ -d "$_mise_shims" ]; then
        case ":$PATH:" in
          *":$_mise_shims:"*) ;;
          *) export PATH="$_mise_shims:$PATH" ;;
        esac
      fi
      unset _mise_data _mise_shims
      ;;
    *)
      eval "$(mise activate bash)"
      ;;
  esac
fi
