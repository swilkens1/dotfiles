#!/usr/bin/env bash
#
# Trust-store tests: run as root by tests/run.sh in a separate throwaway
# container, because they change the system CA store. Windows is faked: a
# stand-in powershell.exe prints whatever certificates a test puts in
# /tmp/ps-output, with Windows line endings.

set -uo pipefail

# shellcheck source=tests/lib.sh
. /src/tests/lib.sh

bundle=/etc/ssl/certs/ca-certificates.crt
trusted() {  # PEM file trusted through both the bundle and the hashed dir?
  openssl verify -no-CApath -CAfile "$bundle" "$1" >/dev/null 2>&1 &&
    openssl verify -no-CAfile -CApath /etc/ssl/certs "$1" >/dev/null 2>&1
}
make_ca() { openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -nodes -keyout /dev/null -subj "/CN=$1" -days 30 -out "$2" 2>/dev/null; }
serve() { cat "$@" 2>/dev/null | sed 's/$/\r/' > /tmp/ps-output; }

make_ca "Test Root One" /tmp/ca1.pem
make_ca "Test Root Two" /tmp/ca2.pem
printf '#!/bin/sh\ncat /tmp/ps-output\n' > /tmp/fake-powershell.exe
chmod +x /tmp/fake-powershell.exe
export SYNC_WINDOWS_CA_POWERSHELL=/tmp/fake-powershell.exe

# The script is embedded in bootstrap.sh (it has to exist before the repo is
# cloned); install it the way bootstrap does.
# shellcheck disable=SC1090
. <(sed -n '/^sync_windows_ca_script() {$/,/^SYNC_WINDOWS_CA$/p' /src/bootstrap.sh; echo '}')
sync_windows_ca_script > /usr/local/sbin/sync-windows-ca
chmod 755 /usr/local/sbin/sync-windows-ca
sync=/usr/local/sbin/sync-windows-ca
run_sync() { "$sync" "$@" >/tmp/sync.out 2>&1; }

# ---- sync-windows-ca --------------------------------------------------------

serve /tmp/ca1.pem /tmp/ca2.pem /tmp/ca1.pem    # duplicate on purpose
check "sync imports Windows roots"     run_sync
check "  ...first root trusted"        trusted /tmp/ca1.pem
check "  ...second root trusted"       trusted /tmp/ca2.pem
check "  ...one file per cert, no duplicates" \
  test "$(find /usr/local/share/ca-certificates/windows-root -name '*.crt' | wc -l)" -eq 2

stamp=$(stat -c %Y "$bundle")
sleep 1
check "re-sync with nothing new succeeds" run_sync
check "  ...leaves the bundle alone"   test "$(stat -c %Y "$bundle")" = "$stamp"

serve /tmp/ca2.pem                              # ca1 rotated out
check "sync after rotation succeeds"   run_sync
check "  ...drops the removed root"    not trusted /tmp/ca1.pem
check "  ...keeps the current root"    trusted /tmp/ca2.pem

serve                                           # export failed: nothing
check "empty export is reported"       not run_sync
check "  ...and keeps existing trust"  trusted /tmp/ca2.pem

# At boot, interop isn't up yet: --boot must return at once and retry later.
rm -rf /usr/local/share/ca-certificates/windows-root && update-ca-certificates >/dev/null 2>&1
serve /tmp/ca2.pem
mv /tmp/fake-powershell.exe /tmp/fake-powershell.off   # "interop not up yet"
SECONDS=0
check "--boot returns immediately"     run_sync --boot
check "  ...within a second (took ${SECONDS}s)" test "$SECONDS" -le 1
sleep 4; mv /tmp/fake-powershell.off /tmp/fake-powershell.exe   # interop is up
for _ in $(seq 20); do trusted /tmp/ca2.pem && break; sleep 1; done
check "  ...and imports once interop is up" trusted /tmp/ca2.pem

# ---- ca-add -----------------------------------------------------------------

ca_add=/src/.local/bin/ca-add
make_ca "Internal GitLab Root" /tmp/ca3.pem
make_ca "DER Root" /tmp/ca4.pem
openssl x509 -in /tmp/ca4.pem -outform DER -out /tmp/ca4.der
run_ca_add() { "$ca_add" "$@" >/tmp/ca-add.out 2>&1; }

check "ca-add trusts a PEM file"       run_ca_add /tmp/ca3.pem internal-gitlab
check "  ...now trusted"               trusted /tmp/ca3.pem
stamp=$(stat -c %Y "$bundle"); sleep 1
check "ca-add again succeeds"          run_ca_add /tmp/ca3.pem internal-gitlab
check "  ...without touching the store" test "$(stat -c %Y "$bundle")" = "$stamp"
check "ca-add accepts DER"             run_ca_add /tmp/ca4.der
check "  ...now trusted"               trusted /tmp/ca4.pem
check "ca-add --list names both"       run_ca_add --list
check "  ...listed"                    grep -q 'internal-gitlab' /tmp/ca-add.out
check "ca-add rejects a non-certificate" not run_ca_add /etc/hostname
check "ca-add leaves Windows roots alone" trusted /tmp/ca2.pem

# ---- Shell environment ------------------------------------------------------

# With Windows roots installed, tools with their own CA bundles are pointed
# at the system bundle.
check "25-ca.sh points AWS at the system bundle" \
  test "$(bash -c '. /src/.bashrc.d/25-ca.sh; echo "$AWS_CA_BUNDLE"')" = "$bundle"

# ---- Boot hook in /etc/wsl.conf ---------------------------------------------

hook="command = $sync --boot"
sections() { grep -c '^\[boot\]' /etc/wsl.conf; }

rm -f /etc/wsl.conf
check "boot hook creates wsl.conf"     run_sync --install-boot-hook
check "  ...with a [boot] command" \
  test "$(cat /etc/wsl.conf)" = "[boot]"$'\n'"$hook"
cp /etc/wsl.conf /tmp/before
check "boot hook re-run succeeds"      run_sync --install-boot-hook
check "  ...changes nothing"           cmp -s /tmp/before /etc/wsl.conf

# Ubuntu's stock WSL config: merge into the existing [boot], keep the rest.
printf '[boot]\nsystemd=true\n\n[user]\ndefault=tester\n' > /etc/wsl.conf
check "boot hook merges into [boot]"   run_sync --install-boot-hook
check "  ...still one [boot] section"  test "$(sections)" -eq 1
check "  ...keeps systemd=true"        grep -qx 'systemd=true' /etc/wsl.conf
check "  ...keeps the [user] section"  grep -qx 'default=tester' /etc/wsl.conf
check "  ...command inside [boot]" \
  test "$(awk '/^\[/{s=$0} $0==h{print s}' h="$hook" /etc/wsl.conf)" = '[boot]'
check "  ...backs up the original"     test -n "$(ls /etc/wsl.conf.bak-* 2>/dev/null)"

# Someone else's boot command: never replaced.
printf '[boot]\ncommand = service docker start\n' > /etc/wsl.conf
cp /etc/wsl.conf /tmp/before
check "foreign boot command is kept"   run_sync --install-boot-hook
check "  ...file unchanged"            cmp -s /tmp/before /etc/wsl.conf
check "  ...explains how to chain"     grep -q 'service docker start; ' /tmp/sync.out

summary
