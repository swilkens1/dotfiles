#!/usr/bin/env bash
#
# Bootstrap dotfiles on a fresh machine.
#
# One-liner (all platforms):
#   curl -fsSL https://raw.githubusercontent.com/swilkens1/dotfiles/master/bootstrap.sh \
#     -o ~/bootstrap.sh && bash ~/bootstrap.sh --run
#
# Running without --run (or --dry-run) prints the flag help and exits,
# so accidental double-clicks or curl|bash pipelines never execute.

set -euo pipefail

# Turn silent `set -e` deaths into loud, line-referenced diagnostics.
# shellcheck disable=SC2154
trap 'rc=$?; printf "\nERROR: bootstrap failed (exit %d) at line %d: %s\n" \
  "$rc" "$LINENO" "$BASH_COMMAND" >&2' ERR

REPO="${DOTFILES_REPO:-https://github.com/swilkens1/dotfiles.git}"

# Bump when you want the bootstrap to pull a newer mise; after install,
# `mise self-update` handles upgrades on existing machines.
MISE_VERSION="2026.6.11"

# bash-completion library, vendored as a single pure-bash file. Pinned and
# checksummed because it gets sourced into every interactive shell.
# Re-pin with:
#   curl -fsSL https://raw.githubusercontent.com/scop/bash-completion/<VER>/bash_completion | sha256sum
BASH_COMPLETION_VERSION="2.16.0"
BASH_COMPLETION_SHA256="f347b832c91d44358bb335e69fa7576241d67040795a1a4d8897317c739d35b1"

# ---- Flags ------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: bootstrap.sh [FLAGS]

Flags:
  --run           Execute the bootstrap.
  --dry-run       Print every action without executing. Combine with
                  --home= for a hermetic sanity check.
  --home=PATH     Use PATH as HOME (sandboxed test mode).
  --help, -h      Show this and exit.

Running without --run or --dry-run prints this help and exits, so an
accidental invocation (double-click, curl|bash) is a no-op.
EOF
}

DRY_RUN=0
DO_RUN=0
if [ $# -eq 0 ]; then usage; exit 0; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --run)     DO_RUN=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --home=*)  HOME="${1#--home=}"; export HOME ;;
    --help|-h) usage; exit 0 ;;
    *)         echo "unknown flag: $1" >&2; usage; exit 1 ;;
  esac
  shift
done
if [ "$DRY_RUN" != 1 ] && [ "$DO_RUN" != 1 ]; then usage; exit 0; fi

CFG="$HOME/.cfg"

# run: execute in real runs, echo in dry-run. Wraps every mutating call so
# --dry-run gives a full audit without touching the filesystem.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf 'DRY: '; printf '%q ' "$@"; printf '\n'
    return 0
  fi
  "$@"
}

# ---- Helpers ----------------------------------------------------------------

config() { git --git-dir="$CFG" --work-tree="$HOME" "$@"; }

# link_dir_win: Windows-only NTFS junction from $link -> $target so
# Windows-native tools (which resolve home via %USERPROFILE%) and the
# shell (via $HOME) see the same physical files. mklink /J needs no
# Admin or Developer Mode; PowerShell's New-Item -ItemType Junction is
# used to avoid MSYS/Git-Bash arg mangling. Idempotent; skips if $link
# already exists as a real directory OR as a symlink.
#
# WARNING: bash's `rm -rf` FOLLOWS junctions and wipes the target. To
# remove the junction only:
#   cmd //c rmdir "$(cygpath -w ~/.claude)"                # from bash
#   [System.IO.Directory]::Delete('C:\path\to\junction')   # from PowerShell
link_dir_win() {
  case "$OSTYPE" in
    msys*|cygwin*) ;;
    *) return 0 ;;
  esac
  local link=$1 target=$2
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    echo "WARN: $link exists and is not a junction; skipping."
    echo "      Move/merge its contents into $target first, then"
    echo "      re-run bootstrap, or remove $link if empty."
    return 0
  fi
  [ -e "$link" ] && return 0
  run mkdir -p "$target"
  local link_w target_w
  link_w=$(cygpath -w "$link")
  target_w=$(cygpath -w "$target")
  echo "Junction: $link  ->  $target"
  run powershell.exe -NoProfile -Command \
    "New-Item -ItemType Junction -Path '$link_w' -Target '$target_w' | Out-Null"
}

# ---- Windows: scoop (CLI) + winget (GUI/system apps) -----------------------

ensure_scoop() {
  if command -v scoop >/dev/null 2>&1; then
    return 0
  fi
  echo "Installing scoop"
  run powershell.exe -NoProfile -Command \
    "Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force; \
     iwr -useb get.scoop.sh | iex"
  # 20-platform.sh puts ~/scoop/shims on PATH for future shells; add it
  # to this script's PATH for the remaining install loop.
  local shims="$HOME/scoop/shims"
  if [ -d "$shims" ]; then
    case ":$PATH:" in *":$shims:"*) ;; *) export PATH="$shims:$PATH" ;; esac
  fi
}

install_windows_cli_tools() {
  ensure_scoop
  local pkg
  for pkg in tmux ripgrep fzf neovim jq bat fd delta; do
    scoop list "$pkg" >/dev/null 2>&1 && continue
    echo "scoop install $pkg"
    run scoop install "$pkg" \
      || echo "  (failed -- run 'scoop install $pkg' by hand to see error)"
  done
}

install_windows_gui_tools() {
  if ! command -v winget.exe >/dev/null 2>&1; then
    cat <<'MSG'
winget not found. Install these manually on Windows:
  - Git for Windows:            https://gitforwindows.org
  - AWS CLI v2:                 https://awscli.amazonaws.com/AWSCLIV2.msi
  - Session Manager Plugin:     https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPlugin.msi
  - Docker Desktop:             https://www.docker.com/products/docker-desktop/
  - Multipass:                  https://multipass.run/
  - VS Code:                    https://code.visualstudio.com/
MSG
    return 0
  fi
  local pkg
  for pkg in \
    Git.Git \
    Amazon.AWSCLI \
    Amazon.SessionManagerPlugin \
    Docker.DockerDesktop \
    Canonical.Multipass \
    Microsoft.VisualStudioCode; do
    winget list --id "$pkg" >/dev/null 2>&1 && continue
    echo "winget install $pkg"
    run winget install --id "$pkg" \
      --accept-source-agreements --accept-package-agreements --silent \
      || echo "  (failed -- corporate AV quarantine? Install manually.)"
  done
}

# ---- bash-completion (all platforms) ---------------------------------------

# Git Bash ships no bash-completion package at all (no /usr/share/bash-completion,
# no /etc/bash_completion.d) -- only git's own completions. Homebrew has
# bash-completion@2, but installs it to a prefix that differs across
# Intel/Apple-Silicon/Linux. Vendoring the single file to one XDG path on every
# OS gives ~/.bashrc.d/70-completions.sh exactly one place to look.
#
# Only the top-level `bash_completion` file is needed, not the upstream
# completions/ tree: modern CLIs generate their own scripts (`kubectl
# completion bash`), they just need this file's helper functions to exist.
ensure_bash_completion() {
  local dest="$HOME/.local/share/bash-completion/bash_completion"
  if [ -f "$dest" ]; then
    return 0
  fi
  echo "Installing bash-completion $BASH_COMPLETION_VERSION"
  run mkdir -p "$(dirname "$dest")"
  local url="https://raw.githubusercontent.com/scop/bash-completion/${BASH_COMPLETION_VERSION}/bash_completion"
  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY: curl $url -> $dest (verify sha256 $BASH_COMPLETION_SHA256)"
    return 0
  fi
  local tmp
  tmp="$(mktemp -t bash_completion.XXXXXX)"
  if ! curl -fsSL -o "$tmp" "$url"; then
    rm -f "$tmp"
    echo "  (download failed -- shell completions will be degraded; re-run later)"
    return 0
  fi
  local got
  got="$(sha256sum "$tmp" | cut -d' ' -f1)"
  if [ "$got" != "$BASH_COMPLETION_SHA256" ]; then
    rm -f "$tmp"
    echo "ERROR: bash-completion checksum mismatch -- refusing to install." >&2
    echo "       expected $BASH_COMPLETION_SHA256" >&2
    echo "       got      $got" >&2
    return 1
  fi
  mv "$tmp" "$dest"
}

# ---- Linux + macOS: Homebrew (single tool matrix) --------------------------

ensure_brew() {
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi
  echo "Installing Homebrew (this takes several minutes on first run)"
  run /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  local brew_bin
  for brew_bin in /home/linuxbrew/.linuxbrew/bin/brew \
                  /opt/homebrew/bin/brew \
                  /usr/local/bin/brew; do
    if [ -x "$brew_bin" ]; then
      eval "$("$brew_bin" shellenv)"
      return 0
    fi
  done
}

install_brew_tools() {
  ensure_brew
  local pkg
  for pkg in awscli session-manager-plugin \
             tmux ripgrep fzf neovim jq bat fd git-delta; do
    brew list "$pkg" >/dev/null 2>&1 && continue
    echo "brew install $pkg"
    run brew install "$pkg" \
      || echo "  (failed -- run 'brew install $pkg' by hand to see error)"
  done
  case "$(uname -s)" in
    Darwin)
      brew list --cask docker    >/dev/null 2>&1 || run brew install --cask docker
      brew list --cask multipass >/dev/null 2>&1 || run brew install --cask multipass
      ;;
    Linux)
      echo "Linux GUI/service apps -- install by hand:"
      echo "  Docker Engine: https://docs.docker.com/engine/install/"
      echo "  Multipass:     snap install multipass"
      ;;
  esac
}

# ---- Main -------------------------------------------------------------------

# 1. Clone bare repo if missing.
if [ ! -d "$CFG" ]; then
  echo "Cloning $REPO into $CFG"
  run git clone --bare "$REPO" "$CFG"
fi

# 2. Force LF line endings on this clone regardless of global git config.
#    Git for Windows defaults core.autocrlf=true, which rewrites `\n` to
#    `\r\n` on checkout -- breaks bash scripts, aws configs, ssh configs.
#    Must run BEFORE the checkout below.
run config config --local core.autocrlf false
run config config --local core.eol lf

# 3. Windows: junction the dirs whose consumers hardcode %USERPROFILE%
#    and have no env-var override. Other dirs (.docker, .kube, .config,
#    .local) are redirected via env vars in ~/.bashrc.d/20-platform.sh.
case "$OSTYPE" in
  msys*|cygwin*)
    USERPROFILE_UNIX=$(cygpath -u "$USERPROFILE")
    link_dir_win "$HOME/.aws"    "$USERPROFILE_UNIX/.aws"
    link_dir_win "$HOME/.claude" "$USERPROFILE_UNIX/.claude"
    link_dir_win "$HOME/.ssh"    "$USERPROFILE_UNIX/.ssh"
    unset USERPROFILE_UNIX
    ;;
esac

# 4. Reconcile $HOME with what the repo will check out. Enumerate every
#    tracked path; if it already exists in $HOME and differs from HEAD,
#    back it up. Then a single `config checkout --force`. $HOME isn't
#    mutated until that final call, so a mid-loop failure leaves $HOME
#    unchanged.
#
#    Guard: refuse --force if there are locally MODIFIED tracked files.
#    --diff-filter=M restricts to modified entries only, so a fresh
#    clone (tracked files show as "deleted from work tree") doesn't
#    false-positive.
if config diff --diff-filter=M --name-only HEAD 2>/dev/null | grep -q .; then
  echo "ERROR: refusing --force checkout -- you have uncommitted modifications:" >&2
  config diff --diff-filter=M --name-only HEAD >&2
  echo "       Commit, stash, or revert them, then re-run bootstrap." >&2
  exit 1
fi
backup_dir="$HOME/.dotfiles-backup"
conflicts=0
while IFS= read -r f; do
  [ -e "$HOME/$f" ] || continue
  if config show "HEAD:$f" 2>/dev/null | cmp -s - "$HOME/$f"; then
    continue
  fi
  if [ "$conflicts" -eq 0 ]; then
    echo "Backing up pre-existing dotfiles to ~/.dotfiles-backup/"
    run mkdir -p "$backup_dir"
  fi
  conflicts=$((conflicts + 1))
  target="$backup_dir/$f"
  [ -e "$target" ] && target="$target.$(date +%s)"
  run mkdir -p "$(dirname "$target")"
  run cp -a "$HOME/$f" "$target"
done < <(config ls-tree -r --name-only HEAD)
run config checkout --force

# 5. Restore info/exclude (per-clone, not pushed). `*` denies by default;
#    the explicit entries document files that must never be `config add -f`'d.
if [ "$DRY_RUN" = 1 ]; then
  echo "DRY: write $CFG/info/exclude"
else
  cat > "$CFG/info/exclude" <<'EOF'
*
# Explicit denies below (belt-and-suspenders with the `*` deny-all above).
# Documents files that must never be `config add -f`'d.
.aws/config
.aws/credentials
.aws/sso
.aws/cli/cache
.local/share/corp-ca.cer
.claude/auth.conf
.claude/settings.local.json
.claude.json
EOF
fi

# 6. Hide untracked from `config status` so the home dir doesn't drown it.
run config config --local status.showUntrackedFiles no

# 7. Per-OS native tool installs + mise installer.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    install_windows_gui_tools
    install_windows_cli_tools
    # Windows: pull the mise release zip from GitHub -- corporate AV
    # sometimes quarantines a winget-extracted binary mid-copy. Both
    # mise.exe and mise-shim.exe are needed (shim silences the
    # "falling back to file shim mode" warning).
    MISE_BIN="$HOME/.local/bin/mise.exe"
    if [ ! -x "$MISE_BIN" ]; then
      echo "Installing mise $MISE_VERSION"
      run mkdir -p "$HOME/.local/bin"
      tmp_zip="$(mktemp -t mise.XXXXXX.zip)"
      run curl -fsSL -o "$tmp_zip" \
        "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-windows-x64.zip"
      run unzip -jo "$tmp_zip" 'mise/bin/mise.exe' 'mise/bin/mise-shim.exe' \
        -d "$HOME/.local/bin/"
      run rm -f "$tmp_zip"
      run chmod +x "$HOME/.local/bin/mise.exe" "$HOME/.local/bin/mise-shim.exe"
    fi
    ;;
  Linux|Darwin)
    install_brew_tools
    MISE_BIN="$HOME/.local/bin/mise"
    if [ ! -x "$MISE_BIN" ]; then
      echo "Installing mise"
      run bash -c 'curl -fsSL https://mise.run | sh'
    fi
    ;;
  *)
    echo "Unknown OS: $(uname -s) -- skipping native-tool and mise installs."
    MISE_BIN=""
    ;;
esac

# 8. bash-completion library. Must land before the first new shell starts;
#    ~/.bashrc.d/70-completions.sh degrades gracefully if it is missing, but
#    Cobra-generated completions (kubectl, docker) silently fail at <TAB>
#    without it.
ensure_bash_completion

# 9. Hydrate mise-managed tools from ~/.config/mise/config.toml. This is what
#    installs `usage`, which mise's own completion dispatcher shells out to.
if [ -n "$MISE_BIN" ] && [ -x "$MISE_BIN" ] && [ -f "$HOME/.config/mise/config.toml" ]; then
  echo "Installing mise-managed tools"
  run "$MISE_BIN" install
fi

# 10. Ensure ~/.claude/settings.local.json exists (machine-local escape
#     hatch). Untracked via info/exclude; the tracked .claude files
#     (settings.json, hooks/, ...) sync through the repo as normal.
run mkdir -p "$HOME/.claude"
if [ ! -f "$HOME/.claude/settings.local.json" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY: write $HOME/.claude/settings.local.json"
  else
    echo '{}' > "$HOME/.claude/settings.local.json"
  fi
fi

cat <<'EOF'

Bootstrap complete.

Manual next steps:

  1. If your machine sits behind a corporate MITM proxy: drop the corp
     CA at ~/.local/share/corp-ca.cer (default), OR export
     CORP_CA_BUNDLE=<path> from a local-only ~/.bashrc.d/9*.sh.
     30-aws.sh picks it up as AWS_CA_BUNDLE.
  2. Configure AWS SSO:               aws configure sso
  3. (Non-SSO profiles only)          edit ~/.aws/credentials manually
  4. Fill in your work email in       ~/.gitconfig-work  (replace [FILL])
  5. (Windows only) if Claude Code can't auto-detect Git Bash, add to
     ~/.claude/settings.local.json:
         { "env": { "CLAUDE_CODE_GIT_BASH_PATH": "C:\\\\Program Files\\\\Git\\\\bin\\\\bash.exe" } }
     Restart Claude Code after editing.
  6. Restart your shell, then:
       config status                  # should be clean
       aws whoami                     # validates alias file (after SSO login)

Windows note -- removing a home-dir junction (~/.aws, ~/.claude, ~/.ssh):
  bash's `rm -rf` FOLLOWS junctions and deletes the target's contents.
  To remove the junction only (target untouched):
    cmd //c rmdir "$(cygpath -w ~/.claude)"                    # from bash
    [System.IO.Directory]::Delete('C:\Users\you\.claude')      # from PowerShell
  Do NOT use `rm -rf`, `rmdir -r`, or PS `Remove-Item` on these paths.

EOF
