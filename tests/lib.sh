# shellcheck shell=bash
# Shared helpers for the tests/assert*.sh scripts.

failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }
check() {
  local name=$1; shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}
not() { ! "$@"; }

summary() {
  echo
  if [ "$failures" -eq 0 ]; then
    echo "All checks passed."
  else
    echo "$failures check(s) failed."
    exit 1
  fi
}
