#!/usr/bin/env bash
#
# Bootstrap dotfiles on a fresh machine.
#
# One-liner:
#   Windows: install MSYS2 first (winget install MSYS2.MSYS2), launch the
#     UCRT64 shell, then:
#     curl -fsSL https://raw.githubusercontent.com/swilkens1/dotfiles/master/bootstrap.sh | bash
#   Linux/macOS: same curl one-liner from any bash-capable shell.
# Or after cloning:
#   bash ~/bootstrap.sh
#
set -euo pipefail

REPO="${DOTFILES_REPO:-https://github.com/swilkens1/dotfiles.git}"
CFG="$HOME/.cfg"

# Bump when you want the bootstrap to pull a newer mise; after install,
# `mise self-update` handles upgrades on existing machines.
MISE_VERSION="2026.6.11"

# ---- Helper functions -------------------------------------------------------

config() { git --git-dir="$CFG" --work-tree="$HOME" "$@"; }

# Windows-only: junction $link -> $target so Windows-native tools (which
# resolve home to %USERPROFILE%) and the shell (which uses $HOME) see the
# same physical files. mklink /J creates NTFS junctions — no Admin or
# Developer Mode required, directories only. Idempotent; skips with a
# warning if $link already exists as a real directory.
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
  [ -d "$target" ] || mkdir -p "$target"
  local link_w target_w
  link_w=$(cygpath -w "$link")
  target_w=$(cygpath -w "$target")
  echo "Junction: $link  ->  $target"
  cmd //c "mklink /J \"$link_w\" \"$target_w\"" >/dev/null
}

install_native_msys2() {
  if command -v pacman >/dev/null 2>&1; then
    # Safety net: pacman keyring init/populate. Newer MSYS2 installers do
    # this automatically, but re-running is idempotent and cheap. If the
    # keyring wasn't set up, `pacman -S` below would fail with GPG errors.
    # Silent unless there's an actual problem.
    # pacman-key --init >/dev/null 2>&1 || true
    # pacman-key --populate msys2 >/dev/null 2>&1 || true

    echo "Installing MSYS2 base packages via pacman"
    pacman -S --needed --noconfirm \
      curl wget unzip jq ripgrep fzf openssh \
      vim less tree which dos2unix tmux
    # Not installing 'git' — Git for Windows has GCM bundled and is
    # installed via winget below.
  fi
}

install_windows_native_tools() {
  if ! command -v winget.exe >/dev/null 2>&1; then
    cat <<'MSG'
winget not found. Install these manually on Windows:
  - Git for Windows:            https://gitforwindows.org
  - AWS CLI v2:                 https://awscli.amazonaws.com/AWSCLIV2.msi
  - Session Manager Plugin:     https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPlugin.msi
  - Docker Desktop:             https://www.docker.com/products/docker-desktop/
  - Multipass:                  https://multipass.run/
MSG
    return 0
  fi
  for pkg in \
    Git.Git \
    Amazon.AWSCLI \
    Amazon.SessionManagerPlugin \
    Docker.DockerDesktop \
    Canonical.Multipass; do
    winget list --id "$pkg" >/dev/null 2>&1 && continue
    echo "winget install $pkg"
    winget install --id "$pkg" \
      --accept-source-agreements --accept-package-agreements --silent \
      || echo "  (failed — corporate AV quarantine? Install manually.)"
  done
}

install_linux_native_tools() {
  if ! command -v aws >/dev/null 2>&1; then
    echo "Installing AWS CLI v2 (bundled)"
    local tmp; tmp=$(mktemp -d)
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
      -o "$tmp/awscliv2.zip"
    (cd "$tmp" && unzip -q awscliv2.zip && sudo ./aws/install)
    rm -rf "$tmp"
  fi
  if ! command -v session-manager-plugin >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      echo "Installing session-manager-plugin (.deb)"
      local deb; deb=$(mktemp --suffix=.deb)
      curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "$deb"
      sudo dpkg -i "$deb"
      rm -f "$deb"
    else
      echo "Install session-manager-plugin manually (no apt-get detected)."
    fi
  fi
  echo "Manual on Linux: Docker Engine (docs.docker.com), Multipass (snap install multipass)."
}

install_macos_native_tools() {
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew not found — install from https://brew.sh, then re-run."
    return 0
  fi
  brew list awscli >/dev/null 2>&1 || brew install awscli
  brew list session-manager-plugin >/dev/null 2>&1 \
    || brew install --cask session-manager-plugin
  brew list --cask docker >/dev/null 2>&1 || brew install --cask docker
  brew list --cask multipass >/dev/null 2>&1 || brew install --cask multipass
}

# ---- Main flow --------------------------------------------------------------

# 1. Clone bare repo if missing.
if [ ! -d "$CFG" ]; then
  echo "Cloning $REPO into $CFG"
  git clone --bare "$REPO" "$CFG"
fi

# 2. Windows only: junction HOME sub-trees BEFORE checkout so tracked files
#    land at USERPROFILE (where Windows-native tools look). No-op on other OSes.
case "$OSTYPE" in
  msys*|cygwin*)
    USERPROFILE_UNIX=$(cygpath -u "$USERPROFILE")
    link_dir_win "$HOME/.aws"    "$USERPROFILE_UNIX/.aws"
    link_dir_win "$HOME/.kube"   "$USERPROFILE_UNIX/.kube"
    link_dir_win "$HOME/.docker" "$USERPROFILE_UNIX/.docker"
    link_dir_win "$HOME/.claude" "$USERPROFILE_UNIX/.claude"
    link_dir_win "$HOME/.config" "$USERPROFILE_UNIX/.config"
    link_dir_win "$HOME/.ssh"    "$USERPROFILE_UNIX/.ssh"
    link_dir_win "$HOME/.local"  "$USERPROFILE_UNIX/.local"
    unset USERPROFILE_UNIX
    ;;
esac

# 3. Checkout; on collision, back up the offenders and retry.
if ! config checkout 2>/dev/null; then
  echo "Backing up pre-existing dotfiles to ~/.dotfiles-backup/"
  mkdir -p "$HOME/.dotfiles-backup"
  config checkout 2>&1 \
    | grep -E "^\s+\." \
    | awk '{print $1}' \
    | while read -r f; do
        mkdir -p "$HOME/.dotfiles-backup/$(dirname "$f")"
        mv "$HOME/$f" "$HOME/.dotfiles-backup/$f"
      done
  config checkout
fi

# 4. Restore info/exclude (per-clone, not pushed). `*` denies by default;
#    the explicit entries document files that must never be `config add -f`'d.
cat > "$CFG/info/exclude" <<'EOF'
*
# Explicit denies below (belt-and-suspenders with the `*` deny-all above).
# Documents files that must never be `config add -f`'d.
.aws/config
.aws/credentials
.aws/corp-ca.cer
.aws/sso
.aws/cli/cache
.claude/auth.conf
.claude/settings.local.json
.claude.json
EOF

# 5. Hide untracked from `config status` so the home dir doesn't drown it.
config config --local status.showUntrackedFiles no

# 6. Create personal/ and work/ dirs so .gitconfig `includeIf` paths resolve
#    immediately on a fresh machine.
mkdir -p "$HOME/personal" "$HOME/work"

# 7. (Optional, cosmetic) pre-install vim-plug + plugins so first `vim`
#    doesn't pause ~10s while .vimrc auto-installs them.
if command -v vim >/dev/null 2>&1; then
  if [ ! -f "$HOME/.vim/autoload/plug.vim" ]; then
    curl -fLo "$HOME/.vim/autoload/plug.vim" --create-dirs \
      https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
  fi
  vim +PlugInstall +qall || true
fi

# 8. Per-OS native tool installs + mise installer.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    install_native_msys2
    install_windows_native_tools
    # Windows: winget is sometimes blocked by corporate AV that quarantines
    # the extracted binary mid-copy, so pull the release zip from GitHub and
    # extract both mise.exe and mise-shim.exe into ~/.local/bin. The shim
    # binary silences mise's "falling back to file shim mode" warning and is
    # needed for shim-based invocation from non-shell contexts (cron,
    # scheduled tasks, some IDEs). If curl gets quarantined too, download
    # the zip via browser to ~/Downloads and run the unzip step manually.
    MISE_BIN="$HOME/.local/bin/mise.exe"
    if [ ! -x "$MISE_BIN" ]; then
      echo "Installing mise $MISE_VERSION"
      mkdir -p "$HOME/.local/bin"
      tmp_zip="$(mktemp -t mise.XXXXXX.zip)"
      curl -fsSL -o "$tmp_zip" \
        "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-windows-x64.zip"
      unzip -jo "$tmp_zip" 'mise/bin/mise.exe' 'mise/bin/mise-shim.exe' \
        -d "$HOME/.local/bin/"
      rm -f "$tmp_zip"
      chmod +x "$HOME/.local/bin/mise.exe" "$HOME/.local/bin/mise-shim.exe"
    fi
    ;;
  Linux)
    install_linux_native_tools
    MISE_BIN="$HOME/.local/bin/mise"
    if [ ! -x "$MISE_BIN" ]; then
      echo "Installing mise"
      curl -fsSL https://mise.run | sh
    fi
    ;;
  Darwin)
    install_macos_native_tools
    MISE_BIN="$HOME/.local/bin/mise"
    if [ ! -x "$MISE_BIN" ]; then
      echo "Installing mise"
      curl -fsSL https://mise.run | sh
    fi
    ;;
  *)
    echo "Unknown OS: $(uname -s) — skipping native-tool and mise installs."
    MISE_BIN=""
    ;;
esac

# 9. Hydrate mise-managed tools from ~/.config/mise/config.toml.
if [ -n "$MISE_BIN" ] && [ -x "$MISE_BIN" ] && [ -f "$HOME/.config/mise/config.toml" ]; then
  echo "Installing mise-managed tools"
  "$MISE_BIN" install
fi

# 10. Ensure ~/.claude/ has a machine-local escape hatch. settings.local.json
#     is where machine-specific values live (e.g., CLAUDE_CODE_GIT_BASH_PATH on
#     Windows). It stays untracked via info/exclude; explicitly-added .claude
#     files (settings.json, hooks/, skills/, commands/, agents/, CLAUDE.md)
#     continue to sync normally.
mkdir -p "$HOME/.claude"
if [ ! -f "$HOME/.claude/settings.local.json" ]; then
  echo '{}' > "$HOME/.claude/settings.local.json"
fi

cat <<'EOF'

Bootstrap complete. Manual next steps:

  1. Windows only: verify MSYS2_PATH_TYPE=strict in C:\msys64\msys2.ini,
     then restart the shell. PATH should be short (only whitelisted entries).
  2. If your machine sits behind a corporate MITM proxy: drop your corp CA at
     ~/.aws/corp-ca.cer, OR export CORP_CA_BUNDLE=<path> from a local-only
     ~/.bashrc.d/9*.sh. 30-aws.sh picks it up as AWS_CA_BUNDLE.
  3. Configure AWS SSO:               aws configure sso
  4. (Non-SSO profiles only)          edit ~/.aws/credentials manually
  5. Fill in your work email in       ~/.gitconfig-work  (replace [FILL])
  6. (Windows only) if Claude Code can't auto-detect your bash, add to
     ~/.claude/settings.local.json:
         { "env": { "CLAUDE_CODE_GIT_BASH_PATH": "C:\\\\msys64\\\\usr\\\\bin\\\\bash.exe" } }
     Point at C:\\Program Files\\Git\\bin\\bash.exe instead if you're on
     Git Bash. Restart Claude Code after editing (env vars load at startup).
  7. Restart your shell, then:
       config status                  # should be clean
       aws whoami                     # validates the alias file (after SSO login)

EOF
