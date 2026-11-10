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
# Empty means the remote's default branch. Set it to test a branch end to end.
BRANCH="${DOTFILES_BRANCH:-}"

# mise version bootstrap installs (Linux and Windows). Bump when you want a
# newer one; after install, `mise self-update` upgrades existing machines.
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
  --with=LIST     Add optional features (comma-separated, repeatable, or
                  "all"). The selection is remembered, so later runs keep it.
  --without=LIST  Remove features; their files leave $HOME.
  --help, -h      Show this and exit.

Without features you get the core: shell, git and vim config. Nothing is
installed. Features:
  cli           tmux, bash-completion (apt); fzf, ripgrep, jq, bat, fd,
                delta, neovim, shellcheck (mise)
  aws           AWS CLI (mise), Session Manager plugin; aps, awsi, ssm helpers
  terraform     terraform, tflint, terraform-ls, trivy, terraform-docs (mise)
  containers    skopeo (apt), kubectl (mise)
  corp-ca       WSL: trust the Windows root CAs (corporate TLS-inspecting
                proxy), now and at every WSL start. Runs before cloning.
  windows-apps  Git Bash: Git, Docker Desktop, Multipass, VS Code (winget)
Installing with apt or dpkg uses sudo.

Behind a TLS-inspecting proxy on WSL, fetch this script with Windows' curl,
which trusts the Windows certificate store, instead of curl -k:
  /mnt/c/Windows/System32/curl.exe -fsSL <raw bootstrap.sh URL> > ~/bootstrap.sh
  bash ~/bootstrap.sh --run --with=corp-ca

Environment:
  DOTFILES_REPO    Clone source (default: the GitHub repo; a local path works).
  DOTFILES_BRANCH  Branch to deploy (default: the remote's default branch).

Running without --run or --dry-run prints this help and exits, so an
accidental invocation (double-click, curl|bash) is a no-op.
EOF
}

FEATURES="cli aws terraform containers corp-ca windows-apps"

DRY_RUN=0
DO_RUN=0
WITH=()
WITHOUT=()
if [ $# -eq 0 ]; then usage; exit 0; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --run)       DO_RUN=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    --home=*)    HOME="${1#--home=}"; export HOME ;;
    --with=*)    IFS=, read -ra list <<<"${1#--with=}"; WITH+=("${list[@]}") ;;
    --without=*) IFS=, read -ra list <<<"${1#--without=}"; WITHOUT+=("${list[@]}") ;;
    --help|-h)   usage; exit 0 ;;
    *)           echo "unknown flag: $1" >&2; usage; exit 1 ;;
  esac
  shift
done
for f in "${WITH[@]}" "${WITHOUT[@]}"; do
  case " all $FEATURES " in
    *" $f "*) ;;
    *) echo "unknown feature: $f (known: $FEATURES, or all)" >&2; exit 1 ;;
  esac
done
if [ "$DRY_RUN" != 1 ] && [ "$DO_RUN" != 1 ]; then usage; exit 0; fi

CFG="$HOME/.cfg"
FEATURES_FILE="$CFG/info/dotfiles-features"

# The selection persists in the clone, so a plain re-run keeps what earlier
# runs added. A clone deployed before features existed got every file, so
# it keeps all of them rather than losing (say) a live ~/.aws.
if [ -f "$FEATURES_FILE" ]; then
  mapfile -t SELECTED <"$FEATURES_FILE"
elif [ -f "$CFG/index" ]; then
  read -ra SELECTED <<<"$FEATURES"
  echo "Existing deployment without a feature list: keeping all features ($FEATURES)."
else
  SELECTED=()
fi
for f in "${WITH[@]}"; do
  if [ "$f" = all ]; then read -ra SELECTED <<<"$FEATURES"; else SELECTED+=("$f"); fi
done
for f in "${WITHOUT[@]}"; do
  if [ "$f" = all ]; then SELECTED=(); continue; fi
  for i in "${!SELECTED[@]}"; do [ "${SELECTED[$i]}" = "$f" ] && unset 'SELECTED[i]'; done
done
# Canonical order, no duplicates, so the saved file only changes when the
# selection does.
mapfile -t SELECTED < <(for f in $FEATURES; do
  for s in "${SELECTED[@]}"; do [ "$s" = "$f" ] && { echo "$f"; break; }; done
done)

# want FEATURE: is it selected (now or by an earlier run)?
want() {
  local f
  for f in "${SELECTED[@]}"; do [ "$f" = "$1" ] && return 0; done
  return 1
}

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

# Real WSL only. The kernel version string is no test: Docker Desktop's
# containers run on the WSL kernel too, but have no interop or distro name.
is_wsl() {
  [ -n "${WSL_DISTRO_NAME:-}" ] ||
    [ -e /proc/sys/fs/binfmt_misc/WSLInterop ] ||
    [ -e /proc/sys/fs/binfmt_misc/WSLInterop-late ]
}

# write_once FILE: create FILE from stdin unless it already exists.
# Machine-local files are seeded once and never overwritten, so a re-run
# keeps whatever you have since put in them.
write_once() {
  local file=$1
  if [ -e "$file" ]; then
    cat >/dev/null
  elif [ "$DRY_RUN" = 1 ]; then
    echo "DRY: write $file"
    cat >/dev/null
  else
    mkdir -p "$(dirname "$file")"
    cat >"$file"
  fi
}

# excluded_paths: tracked paths that stay out of $HOME, as root-anchored
# sparse-checkout patterns (a trailing / means a whole directory). Repo-only
# files never deploy; a feature's files deploy only when it is selected.
# Patterns for files that don't exist yet are harmless.
excluded_paths() {
  printf '%s\n' /README.md /bootstrap.sh /tests/
  want aws        || printf '%s\n' /.aws/ /.bashrc.d/30-aws.sh /.bashrc.d/40-ssm.sh \
                                   /.config/mise/conf.d/aws.toml
  want cli        || printf '%s\n' /.bashrc.d/70-fzf.sh /.config/mise/conf.d/cli.toml
  want terraform  || printf '%s\n' /.bashrc.d/80-terraform.sh /.config/mise/conf.d/terraform.toml
  want containers || printf '%s\n' /.config/mise/conf.d/containers.toml
  case "$OSTYPE" in
    msys*|cygwin*) printf '%s\n' /.local/bin/ca-add ;;
    *)             printf '%s\n' /.local/bin/extract-corp-ca ;;
  esac
}

# deployed PATH: does tracked PATH (relative to the repo root) belong in $HOME?
deployed() {
  local e
  while IFS= read -r e; do
    e=${e#/}
    case "$e" in
      */) case "$1" in "$e"*) return 1 ;; esac ;;
      *)  [ "$1" = "$e" ] && return 1 ;;
    esac
  done < <(excluded_paths)
  return 0
}

# link_dir_win: Windows-only NTFS junction from $link -> $target so
# Windows-native tools (which resolve home via %USERPROFILE%) and the
# shell (via $HOME) see the same physical files. mklink /J needs no
# Admin or Developer Mode; PowerShell's New-Item -ItemType Junction is
# used to avoid MSYS/Git-Bash arg mangling. Idempotent; skips if $link
# already exists as a real directory OR as a symlink.
#
# WARNING: bash's `rm -rf` FOLLOWS junctions and wipes the target. To
# remove the junction only:
#   cmd //c rmdir "$(cygpath -w ~/.aws)"                   # from bash
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

# Resolve scoop's root the way scoop itself does (lib/core.ps1): $SCOOP, else
# %USERPROFILE%\scoop. NOT $HOME -- scoop is a native Windows tool and never
# sees bash's relocated HOME.
scoop_root() {
  local root="${SCOOP:-${USERPROFILE:-$HOME}/scoop}"
  cygpath -u "$root" 2>/dev/null || printf '%s' "$root"
}

ensure_scoop() {
  if command -v scoop >/dev/null 2>&1; then
    return 0
  fi
  echo "Installing scoop"
  run powershell.exe -NoProfile -Command \
    "Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force; \
     iwr -useb get.scoop.sh | iex"
  # scoop's installer only edits the *persistent* Windows PATH, which this
  # already-running process never sees. Add the shims dir to this script's
  # PATH so the install loop below can actually invoke scoop.
  local shims
  shims="$(scoop_root)/shims"
  if [ -d "$shims" ]; then
    case ":$PATH:" in *":$shims:"*) ;; *) export PATH="$shims:$PATH" ;; esac
  fi
}

install_windows_cli_tools() {
  ensure_scoop
  local apps pkg
  apps="$(scoop_root)/apps"
  for pkg in tmux ripgrep fzf neovim jq bat fd delta; do
    # NOT `scoop list "$pkg"`: it exits 0 whether or not the app is installed,
    # so as a guard it silently skipped every package and this whole loop was
    # a no-op. scoop prefix/info are equally useless (both always exit 0).
    # The app directory is the reliable signal.
    [ -d "$apps/$pkg" ] && continue
    echo "scoop install $pkg"
    run scoop install "$pkg" \
      || echo "  (failed -- run 'scoop install $pkg' by hand to see error)"
  done
}

# winget IDs per feature: aws for the CLI and SSM plugin (their MSIs ship
# aws_completer and register with Windows), windows-apps for the rest.
winget_packages() {
  want aws          && printf '%s\n' Amazon.AWSCLI Amazon.SessionManagerPlugin
  want windows-apps && printf '%s\n' Git.Git Docker.DockerDesktop \
                                     Canonical.Multipass Microsoft.VisualStudioCode
  return 0
}

install_windows_gui_tools() {
  local pkgs=() pkg
  mapfile -t pkgs < <(winget_packages)
  [ ${#pkgs[@]} -gt 0 ] || return 0
  if ! command -v winget.exe >/dev/null 2>&1; then
    echo "winget not found. Install these by hand: ${pkgs[*]}"
    return 0
  fi
  for pkg in "${pkgs[@]}"; do
    winget list --id "$pkg" >/dev/null 2>&1 && continue
    echo "winget install $pkg"
    run winget install --id "$pkg" \
      --accept-source-agreements --accept-package-agreements --silent \
      || echo "  (failed -- corporate AV quarantine? Install manually.)"
  done
}

# ---- bash-completion (Git Bash) --------------------------------------------

# Git Bash ships no bash-completion package at all (no /usr/share/bash-completion,
# no /etc/bash_completion.d) -- only git's own completions. Linux uses the
# distro package (apt, --with=cli); here the single library file is vendored
# to the XDG path ~/.bashrc.d/70-completions.sh falls back to.
#
# Only the top-level `bash_completion` file is needed, not the upstream
# completions/ tree: modern CLIs generate their own scripts (`kubectl
# completion bash`), they just need this file's helper functions to exist.
ensure_bash_completion() {
  # Same XDG path 70-completions.sh reads. An existing copy is kept only if
  # it matches the pin, so bumping the version above upgrades on re-run.
  local dest="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/bash_completion"
  if [ -f "$dest" ] &&
     [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$BASH_COMPLETION_SHA256" ]; then
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

# ---- Corporate CA on WSL (--with=corp-ca) -----------------------------------

# The script installed as /usr/local/sbin/sync-windows-ca. Embedded here, not
# tracked as its own file, because behind a TLS-inspecting proxy it has to
# run before git can clone anything. tests/assert-root.sh extracts it from
# the function's opening line to the SYNC_WINDOWS_CA terminator, so keep those.
sync_windows_ca_script() {
  cat <<'SYNC_WINDOWS_CA'
#!/bin/sh
#
# sync-windows-ca: trust the Windows root CAs in this WSL distro, so Linux
# tools accept what Windows accepts -- including a corporate TLS-inspecting
# proxy's CA. Installed by the dotfiles bootstrap.sh (--with=corp-ca).
#
#   sudo sync-windows-ca                      import now
#   sudo sync-windows-ca --install-boot-hook  also run it at every WSL start
#   sync-windows-ca --boot                    (the [boot] command itself)
#
# Approach from https://derrek.dev/blog/2026-09-09-wsl-corporate-ca-passthrough/
# Requires root, WSL interop, and update-ca-certificates (Debian/Ubuntu).

set -eu

# Absolute path: the [boot] command runs before WSL appends the Windows PATH.
ps=${SYNC_WINDOWS_CA_POWERSHELL:-/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe}
# Only this script's own files live here, so stale ones can be removed.
dest=/usr/local/share/ca-certificates/windows-root

say() { echo "sync-windows-ca: $*" >&2; }

[ "$(id -u)" -eq 0 ] || { say "run as root (sudo)"; exit 1; }

# Register this script as the [boot] command in /etc/wsl.conf (it runs as
# root at every WSL start, so a rotated proxy CA is picked up). Merges into
# an existing [boot] section; never replaces someone else's command.
# Microsoft documents [boot] as Windows 11/Server 2022 only; on Windows 10
# check after `wsl --shutdown` that it actually ran.
install_boot_hook() {
  conf=/etc/wsl.conf
  self="/usr/local/sbin/sync-windows-ca --boot"
  current=$(awk '
    /^[[:space:]]*\[/ { boot = ($0 ~ /^[[:space:]]*\[boot\][[:space:]]*$/) }
    boot && /^[[:space:]]*command[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); print }
  ' "$conf" 2>/dev/null || true)
  case "$current" in
    *"$self"*) say "boot hook already in $conf"; return 0 ;;
    "") ;;
    *)
      say "$conf already has a [boot] command: $current"
      say "leaving it alone; to run both, set: command = $current; $self"
      return 0 ;;
  esac
  new=$(mktemp)
  cat "$conf" 2>/dev/null | awk -v cmd="command = $self" '
    { print }
    /^[[:space:]]*\[boot\][[:space:]]*$/ && !done { print cmd; done = 1 }
    END { if (!done) { if (NR) print ""; print "[boot]"; print cmd } }
  ' >"$new"
  if [ -f "$conf" ]; then
    cp -p "$conf" "$conf.bak-$(date +%Y%m%d%H%M%S)"
  fi
  install -m 644 "$new" "$conf"
  rm -f "$new"
  say "added boot hook to $conf; takes effect after 'wsl --shutdown' from Windows"
}
if [ "${1:-}" = --install-boot-hook ]; then
  install_boot_hook
  exit 0
fi

# The [boot] command runs milliseconds after the kernel starts, before
# Windows interop is up, so powershell.exe can't run yet. --boot returns at
# once and retries in the background for up to a minute, logging the outcome
# to the journal.
if [ "${1:-}" = --boot ]; then
  (
    out="interop never came up"
    i=0
    while [ "$i" -lt 20 ]; do
      sleep 3
      i=$((i + 1))
      if out=$("$0" 2>&1); then
        break
      fi
    done
    logger -t sync-windows-ca "$out" 2>/dev/null || true
  ) </dev/null >/dev/null 2>&1 &
  exit 0
fi

[ -x "$ps" ] || { say "$ps not found -- is WSL interop enabled?"; exit 1; }

# Unexpired roots from both stores, deduplicated, as PEM. Sent on stdin, not
# -EncodedCommand, which endpoint security tools commonly flag. The $ are
# PowerShell's, hence single quotes.
# shellcheck disable=SC2016
export_roots='$now = Get-Date; $seen = @{}; foreach ($store in "LocalMachine", "CurrentUser") { foreach ($c in Get-ChildItem "Cert:\$store\Root") { if ($c.NotAfter -lt $now -or $seen.ContainsKey($c.Thumbprint)) { continue }; $seen[$c.Thumbprint] = 1; "-----BEGIN CERTIFICATE-----"; [Convert]::ToBase64String($c.RawData, "InsertLineBreaks"); "-----END CERTIFICATE-----" } }'

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
# Certificates only, so the whole directory can be compared with $dest.
certs="$stage/certs"
mkdir "$certs"

# Windows programs started from a Linux directory complain about UNC paths.
cd /mnt/c 2>/dev/null || cd /

# One certificate per file: OpenSSL's hashed lookup only reads the first
# certificate in each file.
printf '%s\n\n' "$export_roots" |
  "$ps" -NoProfile -NonInteractive -Command - 2>"$stage/powershell.err" |
  tr -d '\r' |
  awk -v dir="$certs" '
    /-----BEGIN CERTIFICATE-----/ { f = sprintf("%s/%05d.pem", dir, ++n) }
    f { print > f }
    /-----END CERTIFICATE-----/ { close(f); f = "" }' || true

# Name each file by its content: re-running then compares like with like,
# and duplicates collapse.
for f in "$certs"/*.pem; do
  [ -e "$f" ] || continue
  if openssl x509 -noout -in "$f" 2>/dev/null; then
    mv "$f" "$certs/windows-root-$(sha256sum "$f" | cut -c1-16).crt"
  else
    rm -f "$f"
  fi
done

count=$(find "$certs" -name '*.crt' | wc -l)
if [ "$count" -eq 0 ]; then
  say "no certificates exported; keeping the ones already installed"
  if [ -s "$stage/powershell.err" ]; then
    say "powershell said: $(tr -d '\r' <"$stage/powershell.err" | head -c 600)"
  fi
  exit 1
fi

if [ -d "$dest" ] && diff -r "$certs" "$dest" >/dev/null 2>&1; then
  say "up to date ($count roots)"
  exit 0
fi

mkdir -p "$dest"
rm -f "$dest"/*.crt
cp "$certs"/*.crt "$dest"/
chmod 644 "$dest"/*.crt
# Many Windows roots are also in Ubuntu's own set; the rehash step reports
# each duplicate. Harmless, so only other warnings are passed on.
if ! update-ca-certificates >/dev/null 2>"$stage/update.err"; then
  cat "$stage/update.err" >&2
  exit 1
fi
grep -v -e 'skipping duplicate certificate' -e 'does not contain exactly one certificate' \
  "$stage/update.err" >&2 || true
say "installed $count Windows roots"
SYNC_WINDOWS_CA
}

# setup_corp_ca: WSL only. Installs (or updates) the script above, then runs
# it, so the clone and package installs that follow already trust the proxy.
setup_corp_ca() {
  if ! is_wsl; then
    case "$OSTYPE" in
      msys*|cygwin*)
        echo "corp-ca: Git Bash has no Linux trust store; after bootstrap, export"
        echo "         the CA with ~/.local/bin/extract-corp-ca instead." ;;
      *)
        echo "corp-ca: not WSL, so there is no Windows store to copy from; after"
        echo "         bootstrap, add your CA with: ca-add <file>" ;;
    esac
    return 0
  fi
  local target=/usr/local/sbin/sync-windows-ca tmp
  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY: install $target, then: ${SUDO[*]} $target; ${SUDO[*]} $target --install-boot-hook"
    return 0
  fi
  tmp=$(mktemp)
  sync_windows_ca_script >"$tmp"
  # Already set up (current script, roots installed, boot hook registered):
  # the boot hook keeps the roots fresh, so don't ask for sudo again.
  if cmp -s "$tmp" "$target" &&
     [ -n "$(ls /usr/local/share/ca-certificates/windows-root 2>/dev/null)" ] &&
     grep -q "^command *=.*$target" /etc/wsl.conf 2>/dev/null; then
    rm -f "$tmp"
    echo "corp-ca: Windows roots already synced; refreshed at every WSL start."
    return 0
  fi
  if ! cmp -s "$tmp" "$target"; then
    echo "Installing $target"
    "${SUDO[@]}" install -m 755 "$tmp" "$target"
  fi
  rm -f "$tmp"
  "${SUDO[@]}" "$target" ||
    echo "WARN: sync-windows-ca failed; HTTPS through the proxy may fail below."
  "${SUDO[@]}" "$target" --install-boot-hook
}

# ---- Linux: apt for OS-level packages, mise for the rest -------------------

# Without a terminal on stdin nobody can type a password, and sudo would
# otherwise wait five minutes per call (WSL still gives it a pty) before
# failing; -n fails at once instead.
SUDO=()
if [ "$(id -u)" -ne 0 ]; then
  if [ -t 0 ]; then SUDO=(sudo); else SUDO=(sudo -n); fi
fi

# Does any selected feature bring a mise tool list?
needs_mise() { want cli || want aws || want terraform || want containers; }

# Distro packages per feature: things mise can't provide or that belong to
# the OS (a terminal multiplexer, the completion framework, skopeo's
# container-signing stack).
apt_packages() {
  want cli        && printf '%s\n' tmux bash-completion
  want containers && printf '%s\n' skopeo
  return 0
}

install_apt_packages() {
  local pkgs=() missing=() p
  mapfile -t pkgs < <(apt_packages)
  [ ${#pkgs[@]} -gt 0 ] || return 0
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "Not Debian/Ubuntu: install with your package manager: ${pkgs[*]}"
    return 0
  fi
  for p in "${pkgs[@]}"; do
    # shellcheck disable=SC2016
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' ||
      missing+=("$p")
  done
  [ ${#missing[@]} -gt 0 ] || return 0
  echo "apt install ${missing[*]}"
  { run "${SUDO[@]}" apt-get update -qq &&
    run "${SUDO[@]}" apt-get install -y --no-install-recommends "${missing[@]}"; } ||
    echo "WARN: apt install failed; install by hand: ${missing[*]}"
}

# AWS's Session Manager plugin (needed by `ssm` / `aws ssm start-session`).
# Not in Ubuntu or mise; AWS publishes a .deb.
install_ssm_plugin() {
  command -v session-manager-plugin >/dev/null 2>&1 && return 0
  local dir url tmp
  case "$(dpkg --print-architecture 2>/dev/null)" in
    amd64) dir=ubuntu_64bit ;;
    arm64) dir=ubuntu_arm64 ;;
    *)
      echo "Install the AWS Session Manager plugin by hand:"
      echo "  https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
      return 0 ;;
  esac
  url="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/$dir/session-manager-plugin.deb"
  echo "Installing the AWS Session Manager plugin"
  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY: curl $url; ${SUDO[*]} dpkg -i session-manager-plugin.deb"
    return 0
  fi
  tmp=$(mktemp --suffix=.deb)
  if curl -fsSL -o "$tmp" "$url" && "${SUDO[@]}" dpkg -i "$tmp" >/dev/null; then
    :
  else
    echo "WARN: Session Manager plugin install failed; see $url"
  fi
  rm -f "$tmp"
}

# ---- Main -------------------------------------------------------------------

# 0. Corporate CA first: behind a TLS-inspecting proxy nothing below can
#    reach GitHub until the proxy's CA is trusted.
if want corp-ca; then
  setup_corp_ca
fi

# 1. Clone bare repo if missing.
if [ ! -d "$CFG" ]; then
  echo "Cloning $REPO${BRANCH:+ ($BRANCH)} into $CFG"
  clone_args=(--bare)
  [ -n "$BRANCH" ] && clone_args+=(--branch "$BRANCH")
  run git clone "${clone_args[@]}" "$REPO" "$CFG"
fi

# 2. Force LF line endings on this clone regardless of global git config.
#    Git for Windows defaults core.autocrlf=true, which rewrites `\n` to
#    `\r\n` on checkout -- breaks bash scripts, aws configs, ssh configs.
#    Must run BEFORE the checkout below.
run config config --local core.autocrlf false
run config config --local core.eol lf

# 2b. A bare clone has no fetch refspec and no upstream, so `config pull`,
#     `config push` and dotsync fail. Give it the layout a normal clone has.
#     Also repairs clones made by older versions of this script.
if [ -d "$CFG" ]; then
  if [ -z "$(config config --get remote.origin.fetch)" ]; then
    run config config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  fi
  run config fetch --quiet origin ||
    echo "WARN: fetch from origin failed; continuing with the local clone."
  cur_branch=$(config symbolic-ref --short HEAD)
  if config rev-parse --verify --quiet "refs/remotes/origin/$cur_branch" >/dev/null &&
     [ "$(config rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" != "origin/$cur_branch" ]; then
    run config branch --quiet --set-upstream-to="origin/$cur_branch"
  fi
  # Fetch stays anonymous HTTPS (works before any key exists); push goes
  # over SSH once the personal key is there. ~/.ssh/config picks the key.
  origin_url=$(config config --get remote.origin.url)
  case "$origin_url" in
    https://github.com/*)
      if [ -f "$HOME/.ssh/id_ed25519_personal" ] &&
         [ -z "$(config config --get remote.origin.pushurl)" ]; then
        run config config remote.origin.pushurl "git@github.com:${origin_url#https://github.com/}"
      fi
      ;;
  esac
else
  echo "DRY: config: set fetch refspec, fetch origin, track origin's branch"
fi

# 3. Which tracked files belong in $HOME: a sparse checkout whose patterns
#    leave out repo-only files and unselected features (excluded_paths).
#    Changing the selection on a deployed clone adds or removes those files
#    via `sparse-checkout reapply`, which never deletes a modified file.
sparse_patterns=$(printf '/*\n'; excluded_paths | sed 's/^/!/')
features_list=$(printf '%s\n' "${SELECTED[@]}" | sed '/^$/d')
if [ -d "$CFG" ]; then
  # --worktree: once `git sparse-checkout` has run, these settings live in
  # config.worktree and override the repo config; without that extension
  # --worktree writes the repo config, same as --local.
  [ "$(config config --get core.sparseCheckout)" = true ] ||
    run config config --worktree core.sparseCheckout true
  [ "$(config config --get core.sparseCheckoutCone)" = false ] ||
    run config config --worktree core.sparseCheckoutCone false
  # The curl'd ~/bootstrap.sh sits at a repo-only path. Git >= 2.37 stops
  # skipping excluded paths that exist on disk, so a `chmod +x` or a newer
  # download shows up as a local change -- and blocks the update in step 4.
  # The setting keeps fresh clones skipping it; --skip-worktree repairs
  # clones deployed before it existed.
  [ "$(config config --get sparse.expectFilesOutsideOfPatterns)" = true ] ||
    run config config --worktree sparse.expectFilesOutsideOfPatterns true
  if [ -f "$CFG/index" ] && [ -e "$HOME/bootstrap.sh" ] &&
     [ "$(config ls-files -t -- bootstrap.sh)" != "S bootstrap.sh" ]; then
    run config update-index --skip-worktree -- bootstrap.sh
  fi
  if [ "$(cat "$CFG/info/sparse-checkout" 2>/dev/null)" != "$sparse_patterns" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      echo "DRY: write $CFG/info/sparse-checkout (features: ${features_list//$'\n'/ })"
    else
      mkdir -p "$CFG/info"
      printf '%s\n' "$sparse_patterns" >"$CFG/info/sparse-checkout"
    fi
    if [ -f "$CFG/index" ]; then
      echo "Applying feature selection: ${features_list:-core only}" | tr '\n' ' '; echo
      run config sparse-checkout reapply ||
        echo "WARN: some files were left in place (local changes?); see above."
    fi
  fi
  # Written even when empty: a missing file means "deployed before features".
  if [ ! -f "$FEATURES_FILE" ] || [ "$(cat "$FEATURES_FILE")" != "$features_list" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      echo "DRY: write $FEATURES_FILE"
    else
      printf '%s' "$features_list${features_list:+$'\n'}" >"$FEATURES_FILE"
    fi
  fi
else
  echo "DRY: deploy core${features_list:+ + ${features_list//$'\n'/ }} (sparse checkout)"
fi

# 3b. Windows: junction the dirs whose consumers hardcode %USERPROFILE%
#     and have no env-var override. Other dirs (.docker, .kube, .config,
#     .local) are redirected via env vars in ~/.bashrc.d/20-platform.sh.
case "$OSTYPE" in
  msys*|cygwin*)
    USERPROFILE_UNIX=$(cygpath -u "$USERPROFILE")
    want aws && link_dir_win "$HOME/.aws" "$USERPROFILE_UNIX/.aws"
    link_dir_win "$HOME/.ssh" "$USERPROFILE_UNIX/.ssh"
    unset USERPROFILE_UNIX
    ;;
esac

# 4. Put the repo's files in $HOME.
#
#    First deploy (the clone has never been checked out, so no index):
#    enumerate every tracked path; if it already exists in $HOME and
#    differs from HEAD, back it up. Then a single `config checkout --force`.
#    $HOME isn't mutated until that final call, so a mid-loop failure
#    leaves $HOME unchanged.
#
#    Re-run: never overwrite local work. Modified or deleted tracked files
#    are reported and left alone; a clean tree fast-forwards to origin.
#
#    A cold dry run has no clone to inspect, so it only describes this step.
if [ "$DRY_RUN" = 1 ] && [ ! -d "$CFG" ]; then
  echo "DRY: back up differing pre-existing dotfiles to ~/.dotfiles-backup/"
  echo "DRY: config checkout --force"
elif [ -f "$CFG/index" ]; then
  local_changes=$(config status --porcelain --untracked-files=no)
  if [ -n "$local_changes" ]; then
    echo "Leaving local changes to tracked dotfiles in place:"
    printf '%s\n' "$local_changes" | sed 's/^/    /'
    echo "  Commit them (dotsync) or revert them (config checkout -- <file>),"
    echo "  then re-run bootstrap to pick up updates from origin."
  elif config rev-parse --verify --quiet '@{upstream}' >/dev/null &&
       [ "$(config rev-parse HEAD)" != "$(config rev-parse '@{upstream}')" ]; then
    if config merge-base --is-ancestor HEAD '@{upstream}'; then
      echo "Updating dotfiles from origin"
      run config merge --ff-only --quiet '@{upstream}' ||
        echo "WARN: update failed (an untracked file in the way?); see the error above."
    else
      echo "WARN: you have dotfile commits not on origin; run dotsync to reconcile."
    fi
  fi
else
  backup_dir="$HOME/.dotfiles-backup"
  conflicts=0
  while IFS= read -r f; do
    deployed "$f" || continue
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
fi

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
.claude
.claude.json
.gitconfig-work
.gitconfig-local
.ssh
EOF
fi

# 6. Hide untracked from `config status` so the home dir doesn't drown it.
run config config --local status.showUntrackedFiles no

# 7. Per-OS native tool installs + mise installer.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    install_windows_gui_tools
    want cli && install_windows_cli_tools
    # Windows: pull the mise release zip from GitHub -- corporate AV
    # sometimes quarantines a winget-extracted binary mid-copy. Both
    # mise.exe and mise-shim.exe are needed (shim silences the
    # "falling back to file shim mode" warning).
    MISE_BIN="$HOME/.local/bin/mise.exe"
    if needs_mise && [ ! -x "$MISE_BIN" ]; then
      echo "Installing mise $MISE_VERSION"
      run mkdir -p "$HOME/.local/bin"
      if [ "$DRY_RUN" = 1 ]; then
        tmp_zip="<tmp>/mise.zip"
      else
        tmp_zip="$(mktemp -t mise.XXXXXX.zip)"
      fi
      run curl -fsSL -o "$tmp_zip" \
        "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-windows-x64.zip"
      run unzip -jo "$tmp_zip" 'mise/bin/mise.exe' 'mise/bin/mise-shim.exe' \
        -d "$HOME/.local/bin/"
      run rm -f "$tmp_zip"
      run chmod +x "$HOME/.local/bin/mise.exe" "$HOME/.local/bin/mise-shim.exe"
    fi
    ;;
  Linux)
    install_apt_packages
    want aws && install_ssm_plugin
    MISE_BIN="$HOME/.local/bin/mise"
    if needs_mise && [ ! -x "$MISE_BIN" ]; then
      echo "Installing mise $MISE_VERSION"
      run bash -c "curl -fsSL https://mise.run | MISE_VERSION=v$MISE_VERSION sh"
    fi
    ;;
  *)
    echo "Unknown OS: $(uname -s) -- skipping native-tool and mise installs."
    MISE_BIN=""
    ;;
esac

# 8. Git Bash + cli: bash-completion library (Linux gets the apt package).
#    Must land before the first new shell starts; 70-completions.sh
#    degrades gracefully if it is missing, but Cobra-generated completions
#    (kubectl, docker) silently fail at <TAB> without it.
case "$OSTYPE" in
  msys*|cygwin*) want cli && ensure_bash_completion ;;
esac

# 9. Hydrate mise-managed tools from ~/.config/mise (config.toml + conf.d/). This is what
#    installs `usage`, which mise's own completion dispatcher shells out to.
#
#    On Windows mise resolves its global config from %USERPROFILE%, not $HOME,
#    and otherwise only finds ours by walking up from $PWD -- so running
#    bootstrap from anywhere outside $HOME would install an empty tool list.
#    Export it explicitly; ~/.bashrc.d/60-mise.sh does the same for shells.
case "$OSTYPE" in
  msys*|cygwin*)
    if [ -d "$HOME/.config/mise" ]; then
      # Not MISE_GLOBAL_CONFIG_FILE: that loads one file and skips conf.d/.
      MISE_CONFIG_DIR=$(cygpath -w "$HOME/.config/mise")
      export MISE_CONFIG_DIR
    fi
    ;;
esac
if ! needs_mise; then
  :
elif [ -n "$MISE_BIN" ] && [ -x "$MISE_BIN" ]; then
  echo "Installing mise-managed tools"
  run "$MISE_BIN" install
elif [ -n "$MISE_BIN" ] && [ "$DRY_RUN" = 1 ]; then
  # Neither mise nor the checked-out config exists yet in a dry run.
  echo "DRY: $MISE_BIN install   (tools from ~/.config/mise)"
fi

# 10. Machine-local git config, never tracked (see info/exclude), so work
#     addresses and host names stay out of the public dotfiles repo.
write_once "$HOME/.gitconfig-work" <<'EOF'
# Work identity for repositories under ~/work/ (included by ~/.gitconfig).
# Machine-local and untracked. Until an email is set here, commits under
# ~/work/ fail instead of using the wrong identity.
[user]
#	email = you@employer.example

# Optional: use SSH for the work Git host even when given an HTTPS URL.
#[url "git@git.employer.example:"]
#	insteadOf = https://git.employer.example/
EOF

#     ~/.gitconfig-local: settings that differ per machine. Each value is
#     only set when missing, so changes you make here survive re-runs.
write_once "$HOME/.gitconfig-local" <<'EOF'
# Per-machine git settings (included last by ~/.gitconfig). Untracked.
# bootstrap.sh fills in missing defaults and never changes existing values.
# Also the place for host-specific CA paths, e.g.
#   [http "https://gitlab.example.internal/"]
#   	sslCAInfo = /path/to/that-host-ca.pem
EOF
gcm_wsl="/mnt/c/Program Files/Git/mingw64/bin/git-credential-manager.exe"
case "$OSTYPE" in
  msys*|cygwin*) helper=manager ;;    # bundled with Git for Windows
  *)
    if is_wsl && [ -x "$gcm_wsl" ]; then
      # Windows' GCM, so HTTPS tokens live in the Windows credential store
      # and are shared with Git for Windows. Git runs the helper through a
      # shell, hence the escaped spaces. The replacement must be quoted:
      # bash 5.2+ drops the backslash from an unquoted `\\ `.
      helper=${gcm_wsl// /'\ '}
    elif command -v git-credential-manager >/dev/null 2>&1; then
      helper=manager
    else
      helper='cache --timeout=28800'  # memory only, 8 hours
    fi
    ;;
esac
if ! git config --file "$HOME/.gitconfig-local" --get credential.helper >/dev/null 2>&1; then
  run git config --file "$HOME/.gitconfig-local" credential.helper "$helper"
fi

# Closing notes: only the steps that apply to this machine and are still
# open, so a re-run on a finished machine says little.
echo
echo "Bootstrap complete. Features: ${features_list:-none (core only)}" | tr '\n' ' '
echo
echo "  (add or remove with --with= / --without=; see --help)"
steps=("Open a new shell (exec bash -l); then \`config status\` should be clean.")
if [ -z "$(git config --file "$HOME/.gitconfig-work" --get user.email 2>/dev/null)" ]; then
  steps+=("Set your work email in ~/.gitconfig-work (local, never committed).")
fi
if want aws && [ ! -s "${AWS_CONFIG_FILE:-$HOME/.aws/config}" ]; then
  steps+=("Set up AWS SSO: aws configure sso; then check with: aws whoami")
fi
if want terraform && [ ! -f "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/tf-accounts" ]; then
  steps+=("For tfi/tfp/tfa, map account IDs to tfvars files in ~/.config/dotfiles/tf-accounts (see ~/.bashrc.d/80-terraform.sh).")
fi
if ! want corp-ca; then
  case "$OSTYPE" in
    msys*|cygwin*) steps+=("Behind a TLS-inspecting proxy: extract-corp-ca writes the CA for the AWS CLI.") ;;
    *) if is_wsl; then
         steps+=("Behind a TLS-inspecting proxy: re-run with --with=corp-ca to trust the Windows CAs.")
       else
         steps+=("Behind a TLS-inspecting proxy: ca-add FILE trusts its CA system-wide.")
       fi ;;
  esac
fi
echo
echo "Next steps:"
for i in "${!steps[@]}"; do
  printf '  %d. %s\n' "$((i + 1))" "${steps[$i]}"
done
echo
case "$OSTYPE" in
  msys*|cygwin*)
    cat <<'EOF'
Windows note -- removing a home-dir junction (~/.aws, ~/.ssh):
  bash's `rm -rf` FOLLOWS junctions and deletes the target's contents.
  To remove the junction only (target untouched):
    cmd //c rmdir "$(cygpath -w ~/.aws)"                       # from bash
    [System.IO.Directory]::Delete('C:\Users\you\.aws')         # from PowerShell
  Do NOT use `rm -rf`, `rmdir -r`, or PS `Remove-Item` on these paths.

EOF
    ;;
esac

# SSH keys are per machine and never generated here; say what's missing.
missing_keys=()
for k in personal work; do
  [ -f "$HOME/.ssh/id_ed25519_$k" ] || missing_keys+=("$k")
done
if [ ${#missing_keys[@]} -gt 0 ]; then
  echo "SSH keys not found: ${missing_keys[*]}. Create them with:"
  for k in "${missing_keys[@]}"; do
    echo "    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_$k -C \"$k ${HOSTNAME:-$(uname -n)}\""
  done
  cat <<'EOF'
  Add each .pub to its Git host, then pick keys per host in ~/.ssh/config:
    Host github.com
      IdentityFile ~/.ssh/id_ed25519_personal
    Host <work-git-host>
      IdentityFile ~/.ssh/id_ed25519_work
    Host *
      IdentitiesOnly yes
      AddKeysToAgent yes
  If the network blocks port 22, add to the github.com entry:
      Hostname ssh.github.com
      Port 443
  Check with: ssh -T git@github.com

EOF
fi
