#!/usr/bin/env bash
#
# End-to-end bootstrap test in a throwaway Ubuntu container.
#
#   tests/run.sh
#   TEST_CA_BUNDLE=/path/to/corp-ca.pem tests/run.sh   # behind a TLS-inspecting proxy
#
# Deploys the committed HEAD of the current branch (bootstrap installs
# commits, never the working tree), using the working-tree bootstrap.sh.
# Works from WSL/Linux and from Git Bash with Docker Desktop.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)

if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no -- . ':!bootstrap.sh' ':!tests')" ]; then
  echo "NOTE: uncommitted dotfile changes are not deployed; testing HEAD of $branch." >&2
fi

ctx=$(mktemp -d)
trap 'rm -rf "$ctx"' EXIT
mkdir "$ctx/ca"
if [ -n "${TEST_CA_BUNDLE:-}" ]; then
  cp "$TEST_CA_BUNDLE" "$ctx/ca/test-ca.crt"
fi
cp "$here/Dockerfile" "$ctx/"
docker build --quiet --tag dotfiles-test "$ctx" >/dev/null

# Docker Desktop on Windows needs a Windows-form path and no MSYS argument
# mangling; on Linux/WSL the path is used as-is.
src=$repo
if command -v cygpath >/dev/null 2>&1; then
  src=$(cygpath -m "$repo")
fi
rc=0
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$src:/src:ro" \
  -e DOTFILES_BRANCH="$branch" \
  dotfiles-test bash /src/tests/assert.sh || rc=1

echo
echo "== As root (system trust store) =="
MSYS_NO_PATHCONV=1 docker run --rm --user root \
  -v "$src:/src:ro" \
  dotfiles-test bash /src/tests/assert-root.sh || rc=1
exit "$rc"
