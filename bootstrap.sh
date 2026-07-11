#!/usr/bin/env bash
#
# Bootstrap dotfiles on a fresh machine.
#
# One-liner (Windows: launch UCRT64 shell first, from `winget install MSYS2.MSYS2`):
#   curl -fsSL https://raw.githubusercontent.com/swilkens1/dotfiles/master/bootstrap.sh -o ~/bootstrap.sh \
#     && bash ~/bootstrap.sh
#
# Do NOT run via `curl ... | bash`. Several child processes spawned below
# (cmd.exe for mklink, winget, vim) inherit the piped stdin and consume
# the rest of the script as if it were their own input. Materialize to
# disk first, then bash it.
#
set -euo pipefail

# Turn silent `set -e` deaths into loud, line-referenced diagnostics.
# Without this trap, any command that exits nonzero — including
# unintentional pipefail triggers, missing packages, or typo'd paths —
# kills the shell without a hint. `$LINENO` in the trap resolves to the
# line that actually failed, `$BASH_COMMAND` gives you the offending
# command verbatim.
# shellcheck disable=SC2154  # rc is assigned inline in the trap string
trap 'rc=$?; printf "\nERROR: bootstrap failed (exit %d) at line %d: %s\n" \
  "$rc" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Refuse to run from a pipe. Several child processes below (cmd.exe for
# mklink, winget, vim) inherit our stdin and will consume the remainder
# of the script as their own input, silently corrupting the run. See
# BASH_SOURCE — it's a real path when we're invoked as a file, and
# 'bash' / empty when we're being fed via `curl … | bash`.
if [ ! -f "${BASH_SOURCE[0]:-/dev/null}" ]; then
  cat >&2 <<'ERR'
ERROR: bootstrap.sh is being run from a pipe (looks like `curl … | bash`).
       Child processes inherit the pipe as stdin and eat the rest of
       the script. Download to disk first, then run:

         curl -fsSL https://raw.githubusercontent.com/swilkens1/dotfiles/master/bootstrap.sh \
           -o ~/bootstrap.sh
         bash ~/bootstrap.sh
ERR
  exit 1
fi

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
#
# Removing a junction without nuking the target (bash's `rm -rf` FOLLOWS
# junctions and wipes the target's contents — do not use it):
#   cmd //c rmdir "$(cygpath -w ~/.aws)"                    # from bash
#   [System.IO.Directory]::Delete('C:\path\to\junction')    # from PowerShell
# (PS's `Remove-Item` has historically followed junctions in 5.1; use
# Directory.Delete to be safe.)
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
  # PowerShell's New-Item -ItemType Junction, not `cmd //c mklink /J`:
  # MSYS2's arg-to-CommandLine conversion mangles the quoted mklink
  # string enough that cmd rejects it with "syntax is incorrect".
  powershell.exe -NoProfile -Command \
    "New-Item -ItemType Junction -Path '$link_w' -Target '$target_w' | Out-Null"
}

# Ensure git is on PATH before we try to clone the bare repo. On fresh
# Windows/MSYS2, Git for Windows may not yet be visible even if installed
# (per-user installs under AppData don't always land in MSYS2's inherited
# PATH). Fixes the chicken-and-egg where install_windows_native_tools
# would install Git.Git but only in step 8, AFTER the clone in step 1.
ensure_git_available() {
  if command -v git >/dev/null 2>&1; then
    return 0
  fi

  case "$OSTYPE" in
    msys*|cygwin*)
      # Check common Git for Windows install locations.
      local candidates=(
        "/c/Program Files/Git/cmd"
        "/c/Users/$USERNAME/AppData/Local/Programs/Git/cmd"
      )
      local found=""
      for dir in "${candidates[@]}"; do
        [ -x "$dir/git.exe" ] && { found="$dir"; break; }
      done

      # Not on disk — try winget install.
      if [ -z "$found" ] && command -v winget.exe >/dev/null 2>&1; then
        echo "git not found — installing Git for Windows via winget (~30s)"
        winget install --id Git.Git \
          --accept-source-agreements --accept-package-agreements --silent \
          || echo "  (winget install failed — install manually from https://gitforwindows.org)"
        for dir in "${candidates[@]}"; do
          [ -x "$dir/git.exe" ] && { found="$dir"; break; }
        done
      fi

      if [ -z "$found" ]; then
        echo "FATAL: git not found after install attempts." >&2
        echo "       Install Git for Windows from https://gitforwindows.org," >&2
        echo "       then re-run bootstrap." >&2
        exit 1
      fi

      echo "Using Git for Windows at $found"
      export PATH="$found:$PATH"
      ;;
    *)
      echo "FATAL: git not found. Install it (apt install git / brew install git / etc.)," >&2
      echo "       then re-run bootstrap." >&2
      exit 1
      ;;
  esac
}

install_native_msys2() {
  command -v pacman >/dev/null 2>&1 || return 0
  echo "Installing MSYS2 base packages via pacman"

  # Packages in the plain `msys` repo — no subsystem prefix. We install
  # one at a time so a single missing target doesn't abort the batch
  # (pacman -S is transactional; --needed makes already-installed
  # packages a no-op). `git` is intentionally excluded — Git for Windows
  # (installed via winget below) is preferred for its bundled GCM.
  local pkg fails=()
  for pkg in curl wget unzip jq openssh vim less tree which dos2unix tmux diffutils; do
    pacman -S --needed --noconfirm "$pkg" >/dev/null 2>&1 \
      || fails+=("$pkg")
  done

  # Subsystem-prefixed packages (ripgrep, fzf) live in the mingw/ucrt/
  # clang repos, not msys. $MINGW_PACKAGE_PREFIX is set by each MSYS2
  # subsystem shell (e.g. "mingw-w64-ucrt-x86_64" under UCRT64). If it's
  # unset (running under plain msys), skip these — they're comforts, not
  # correctness-critical.
  if [ -n "${MINGW_PACKAGE_PREFIX:-}" ]; then
    for pkg in ripgrep fzf; do
      pacman -S --needed --noconfirm "${MINGW_PACKAGE_PREFIX}-${pkg}" >/dev/null 2>&1 \
        || fails+=("${MINGW_PACKAGE_PREFIX}-${pkg}")
    done
  else
    echo "  (skipping ripgrep/fzf: no MINGW_PACKAGE_PREFIX set)"
  fi

  if [ "${#fails[@]}" -gt 0 ]; then
    echo "  WARN: could not install: ${fails[*]}"
    echo "        (missing from configured repos; check https://packages.msys2.org)"
  fi
}

# Install the MSYS2 packages the EARLY steps of the bootstrap depend on,
# before the full `install_native_msys2` runs. Fresh UCRT64 installs are
# extremely minimal — notably, `cmp` (diffutils) is missing, and the
# reconciliation loop below relies on it to compare $HOME files against
# HEAD. Anything the later `install_native_msys2` also installs is fine
# to duplicate here; --needed makes pacman a no-op when up to date.
preflight_msys2_pkgs() {
  case "$OSTYPE" in
    msys*|cygwin*) ;;
    *) return 0 ;;
  esac
  command -v pacman >/dev/null 2>&1 || return 0
  # cmp is needed by the reconciliation loop; add here anything else the
  # steps before `install_native_msys2` require.
  pacman -S --needed --noconfirm diffutils >/dev/null
}

# Verify every external command the script depends on is present and
# every required env var is set. Runs AFTER preflight_msys2_pkgs so
# freshly-installed packages count. Fails fast with a punch list rather
# than mid-run at a random line.
preflight_check() {
  local missing_cmds=() missing_env=()
  local cmd env_var

  # Commands used before install_native_msys2 runs. cmp lives in
  # diffutils (installed by preflight); the rest are coreutils/bash.
  for cmd in git curl cp mv mkdir dirname cmp grep awk sed; do
    command -v "$cmd" >/dev/null 2>&1 || missing_cmds+=("$cmd")
  done
  case "$OSTYPE" in
    msys*|cygwin*)
      for cmd in cygpath powershell.exe; do
        command -v "$cmd" >/dev/null 2>&1 || missing_cmds+=("$cmd")
      done
      for env_var in USERPROFILE MINGW_PACKAGE_PREFIX; do
        [ -n "${!env_var:-}" ] || missing_env+=("$env_var")
      done
      ;;
  esac

  if [ "${#missing_cmds[@]}" -gt 0 ] || [ "${#missing_env[@]}" -gt 0 ]; then
    echo "ERROR: preflight failed. Missing prerequisites:" >&2
    [ "${#missing_cmds[@]}" -gt 0 ] && echo "  commands: ${missing_cmds[*]}" >&2
    [ "${#missing_env[@]}"  -gt 0 ] && echo "  env vars: ${missing_env[*]}" >&2
    echo "" >&2
    echo "  Install the missing commands (pacman -S <pkg> on MSYS2; see" >&2
    echo "  https://packages.msys2.org to look up file→package), export" >&2
    echo "  the missing env vars, and re-run." >&2
    exit 1
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

# 0. Prereqs: git for the clone (installed via winget on Windows if
#    missing), a minimal set of MSYS2 packages the reconciliation loop
#    below needs (notably `cmp`, which a stock UCRT64 install lacks),
#    then a preflight validation that fails fast with a punch list of
#    anything still missing before we touch the filesystem.
ensure_git_available
preflight_msys2_pkgs
preflight_check

# 1. Clone bare repo if missing.
if [ ! -d "$CFG" ]; then
  echo "Cloning $REPO into $CFG"
  git clone --bare "$REPO" "$CFG"
fi

# 1b. Force LF line endings on checkout, regardless of global git config.
#     Git for Windows defaults core.autocrlf=true, which rewrites every
#     `\n` to `\r\n` on checkout — that breaks bash scripts, aws configs,
#     ssh configs, everything Unix-side parsers touch. Setting these on
#     the bare repo's local config keeps files byte-identical to HEAD
#     across platforms and takes effect BEFORE the checkout below.
config config --local core.autocrlf false
config config --local core.eol lf

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

# 3. Reconcile $HOME with what the repo will check out. Enumerate every
#    tracked path; for each one already present in $HOME (possibly via a
#    junction), decide:
#      - identical to HEAD -> no-op (checkout --force overwrites in
#                             place with the same bytes; harmless)
#      - differs           -> cp -a into ~/.dotfiles-backup/, uniquifying
#                             the target if a prior run already backed it up
#      - missing           -> no-op (checkout will place it fresh)
#    Then a single `config checkout --force`. $HOME isn't mutated until
#    that final call, so a mid-loop failure leaves $HOME unchanged.
#
#    Guard: refuse --force if there are locally MODIFIED tracked files —
#    --force would clobber them. --diff-filter=M restricts to modified
#    entries only, so a fresh clone (where tracked files show up as
#    "deleted from work tree") doesn't false-positive.
if config diff --diff-filter=M --name-only HEAD 2>/dev/null | grep -q .; then
  echo "ERROR: refusing --force checkout — you have uncommitted modifications:" >&2
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
    mkdir -p "$backup_dir"
  fi
  conflicts=$((conflicts + 1))
  target="$backup_dir/$f"
  [ -e "$target" ] && target="$target.$(date +%s)"
  mkdir -p "$(dirname "$target")"
  cp -a "$HOME/$f" "$target"
done < <(config ls-tree -r --name-only HEAD)
config checkout --force

# 4. Restore info/exclude (per-clone, not pushed). `*` denies by default;
#    the explicit entries document files that must never be `config add -f`'d.
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

# 5. Hide untracked from `config status` so the home dir doesn't drown it.
config config --local status.showUntrackedFiles no

# 6. Create personal/ and work/ dirs so .gitconfig `includeIf` paths resolve
#    immediately on a fresh machine.
mkdir -p "$HOME/personal" "$HOME/work"

# 7. Per-OS native tool installs + mise installer. Runs BEFORE the
#    vim-plug preinstall below so `vim` is available on a fresh box.
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

# 8. (Optional, cosmetic) pre-install vim-plug + plugins so first `vim`
#    doesn't pause ~10s while .vimrc auto-installs them. Deferred until
#    after step 7 so vim is actually installed on fresh boxes.
if command -v vim >/dev/null 2>&1; then
  if [ ! -f "$HOME/.vim/autoload/plug.vim" ]; then
    curl -fLo "$HOME/.vim/autoload/plug.vim" --create-dirs \
      https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
  fi
  vim +PlugInstall +qall </dev/null || true
fi

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

Bootstrap complete.

Windows note — removing a home-dir junction (~/.aws, ~/.kube, etc.):
  bash's `rm -rf` FOLLOWS junctions and deletes the target's contents.
  To remove the junction only (target untouched):
    cmd //c rmdir "$(cygpath -w ~/.aws)"                    # from bash
    [System.IO.Directory]::Delete('C:\Users\you\.aws')      # from PowerShell
  Do NOT use `rm -rf`, `rmdir -r`, or PS `Remove-Item` on these paths.

Manual next steps:

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
