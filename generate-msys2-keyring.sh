#!/bin/bash
#
# Generate a populated MSYS2 pacman keyring inside a Linux Docker container
# and extract it to the host. Sidesteps corp AV that blocks gpg.exe
# from running trustdb updates in /etc/pacman.d/gnupg/ on the Windows host.
#
# Usage:
#   ./generate-msys2-keyring.sh [OUT_DIR]
#
# Env vars (all optional):
#   CORP_CA_BUNDLE  Path to corp CA cert (PEM/CER). If set and the file
#                   exists, gets mounted into the container and installed
#                   into its trust store before any HTTPS calls. Defaults
#                   to ~/.local/share/corp-ca.cer. Set to "" to force-skip
#                   (personal / non-MITM machine).
#   KEYRING_URL     Direct URL to the msys2-keyring .pkg.tar.zst. Bump when
#                   msys2 publishes a new version. Browse
#                   https://repo.msys2.org/msys/x86_64/ for the current one.
#
# Requires: Docker Desktop running, bash, cygpath (Git Bash / MSYS2 shell).
#
set -euo pipefail

OUT_DIR="${1:-$HOME/msys2-keyring-out}"
mkdir -p "$OUT_DIR"
OUT_WIN=$(cygpath -w "$OUT_DIR")

# Resolve corp CA path. `CORP_CA_BUNDLE=""` explicitly forces skip.
CORP_CA_BUNDLE="${CORP_CA_BUNDLE:-$HOME/.local/share/corp-ca.cer}"

# Bump this when msys2 publishes a new keyring release. Check
# https://repo.msys2.org/msys/x86_64/ for msys2-keyring-*.pkg.tar.zst
KEYRING_URL="${KEYRING_URL:-https://repo.msys2.org/msys/x86_64/msys2-keyring-1~20260214-1-any.pkg.tar.zst}"

docker_args=(--rm -v "${OUT_WIN}:/output")
if [ -n "$CORP_CA_BUNDLE" ] && [ -f "$CORP_CA_BUNDLE" ]; then
  echo "Mounting corp CA into container: $CORP_CA_BUNDLE"
  CA_WIN=$(cygpath -w "$CORP_CA_BUNDLE")
  docker_args+=(-v "${CA_WIN}:/tmp/corp-ca.cer:ro")
else
  echo "No corp CA (CORP_CA_BUNDLE unset or file missing) — assuming direct network."
fi

echo "Using KEYRING_URL: $KEYRING_URL"
echo "Output tarball dir: $OUT_DIR"
echo ""

docker run "${docker_args[@]}" \
  -e KEYRING_URL="$KEYRING_URL" \
  archlinux:latest bash -c '
    set -euo pipefail

    # Install corp CA into the container trust store BEFORE any HTTPS calls.
    if [ -f /tmp/corp-ca.cer ]; then
      echo "Installing corp CA into container trust store"
      cp /tmp/corp-ca.cer /etc/ca-certificates/trust-source/anchors/
      update-ca-trust extract
    fi

    # Retry wrapper for flaky network calls. Exponential backoff, capped at 3 tries.
    retry() {
      local max=3 delay=5 attempt=1
      while [ $attempt -le $max ]; do
        if "$@"; then return 0; fi
        echo "  Attempt $attempt/$max failed; retrying in ${delay}s..." >&2
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
      done
      echo "  All $max attempts failed for: $*" >&2
      return 1
    }

    # Only sync + install if tools are actually missing.
    missing=()
    for tool in curl tar; do
      command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if [ ${#missing[@]} -gt 0 ]; then
      echo "Missing tools in base image: ${missing[*]} — running pacman -Sy"
      if ! retry pacman -Sy --noconfirm --needed "${missing[@]}"; then
        # pacman may have partially succeeded even on non-zero exit
        # Re-check before giving up.
        for tool in "${missing[@]}"; do
          command -v "$tool" >/dev/null 2>&1 \
            || { echo "FATAL: $tool still missing after retries" >&2; exit 1; }
        done
        echo "pacman -Sy exited non-zero but ${missing[*]} landed anyway; continuing."
      fi
    else
      echo "curl + tar already in base image; skipping pacman -Sy"
    fi

    mkdir -p /work && cd /work
    echo "Downloading $KEYRING_URL"
    # --retry-connrefused + retry wrapper handles both curl-internal retries
    # (connection-level) and full-invocation retries (mirror gave up mid-stream).
    retry curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 30 \
      "$KEYRING_URL" -o msys2-keyring.pkg.tar.zst
    tar -xf msys2-keyring.pkg.tar.zst

    install -Dm644 usr/share/pacman/keyrings/msys2.gpg     /usr/share/pacman/keyrings/msys2.gpg
    install -Dm644 usr/share/pacman/keyrings/msys2-trusted /usr/share/pacman/keyrings/msys2-trusted
    install -Dm644 usr/share/pacman/keyrings/msys2-revoked /usr/share/pacman/keyrings/msys2-revoked 2>/dev/null || true

    mkdir -p /work/gnupg
    chmod 700 /work/gnupg
    pacman-key --gpgdir /work/gnupg --init
    pacman-key --gpgdir /work/gnupg --populate msys2

    cd /work
    tar -czf /output/pacman-gnupg.tar.gz --owner=0 --group=0 gnupg/
    ls -la /output/
  '

echo ""
echo "Container finished. Tarball at $OUT_DIR/pacman-gnupg.tar.gz"
echo ""
echo "Next steps on this MSYS2 host:"
echo "  rm -rf /etc/pacman.d/gnupg"
echo "  tar -xzf $OUT_DIR/pacman-gnupg.tar.gz -C /etc/pacman.d/"
echo "  pacman -Sy tmux    # verify signature-checked install works"
