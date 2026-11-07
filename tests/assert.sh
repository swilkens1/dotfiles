#!/usr/bin/env bash
#
# Runs inside the tests/run.sh container as an unprivileged user with a fresh
# home. Not meant to be run on a real machine.

set -uo pipefail

[ -d /src/.git ] || { echo "expected the repo mounted at /src" >&2; exit 2; }

# A writable copy of the repo stands in for GitHub, so pull/push can be
# exercised without touching the real remote. /src is owned by another uid.
git -c safe.directory='*' clone --quiet --bare \
  --branch "${DOTFILES_BRANCH:?}" /src /tmp/remote.git
export DOTFILES_REPO=/tmp/remote.git

# Stand-ins for downloads bootstrap skips when present (Homebrew is stubbed
# in the image). Keeps the test hermetic and fast.
mkdir -p ~/.local/bin ~/.local/share/bash-completion
printf '#!/bin/sh\nexit 0\n' > ~/.local/bin/mise
chmod +x ~/.local/bin/mise
: > ~/.local/share/bash-completion/bash_completion
export PATH="/opt/stubs/bin:$PATH"

failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }
check() {
  local name=$1; shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

config() { git --git-dir="$HOME/.cfg" --work-tree="$HOME" "$@"; }

log=/tmp/bootstrap.log
bootstrap() {
  bash /src/bootstrap.sh "$@" >"$log" 2>&1
  local rc=$?
  [ "$rc" -eq 0 ] || { echo "--- bootstrap $* (exit $rc) ---"; cat "$log"; }
  return "$rc"
}

# Everything in $HOME a re-run must leave alone. Git's own bookkeeping
# (objects, index stat data, FETCH_HEAD, logs) legitimately changes.
snapshot() {
  (cd "$HOME" && find . \
    \( -path ./.cfg/objects -o -path ./.cfg/logs \
       -o -path ./.cfg/index -o -path ./.cfg/FETCH_HEAD \) -prune \
    -o -type f -print0 | sort -z | xargs -0 sha256sum)
}

# ---- Dry run on a cold machine ----------------------------------------------

# No Homebrew stub on PATH, so bootstrap takes its install branches; curl is
# replaced by a recorder. A dry run must not download, create, or complain.
mkdir -p /tmp/rec /tmp/dryhome
printf '#!/bin/sh\necho "$*" >> /tmp/curl.calls\n' > /tmp/rec/curl
chmod +x /tmp/rec/curl
PATH=/tmp/rec:/usr/local/bin:/usr/bin:/bin \
  bash /src/bootstrap.sh --dry-run --home=/tmp/dryhome >/tmp/dry.out 2>/tmp/dry.err
check "dry run succeeds"              test $? -eq 0
check "dry run calls no curl"         test ! -e /tmp/curl.calls
check "dry run creates no files"      test -z "$(find /tmp/dryhome -mindepth 1)"
check "dry run prints no errors"      test ! -s /tmp/dry.err
check "dry run previews mise tools"   grep -q 'mise.* install' /tmp/dry.out
[ ! -s /tmp/dry.err ] || sed 's/^/     | /' /tmp/dry.err

# ---- First run on a fresh home ----------------------------------------------

check "first run succeeds"            bootstrap --run
check "tracked files deployed, clean" test -z "$(config status --porcelain)"
check "skel .bashrc backed up"        cmp -s /etc/skel/.bashrc ~/.dotfiles-backup/.bashrc

# ---- Re-run is a no-op ------------------------------------------------------

before=$(snapshot)
check "second run succeeds"           bootstrap --run
check "second run changes nothing"    test "$before" = "$(snapshot)"

# ---- Shell startup ----------------------------------------------------------

# Errors from an interactive login shell, minus the job-control complaints any
# interactive bash prints without a terminal.
startup_errors() {
  bash -lic true 2>&1 >/dev/null |
    grep -v -e 'cannot set terminal process group' -e 'no job control in this shell'
}
errs=$(startup_errors)
check "login shell starts without errors" test -z "$errs"
[ -z "$errs" ] || printf '     | %s\n' "$errs"

# Ubuntu's stock ~/.profile also sources ~/.bashrc; modules must load once.
loads=$(bash -lixc true 2>&1 | grep -c "^+* \. $HOME/\.bashrc\.d/10-prompt\.sh$")
check "login shell loads modules once (got $loads)" test "$loads" -eq 1

echo
if [ "$failures" -eq 0 ]; then
  echo "All checks passed."
else
  echo "$failures check(s) failed."
  exit 1
fi
