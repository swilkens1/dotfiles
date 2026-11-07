#!/usr/bin/env bash
#
# Runs inside the tests/run.sh container as an unprivileged user with a fresh
# home. Not meant to be run on a real machine.

# Check names mention ~/ paths as plain labels, not as paths to expand, and
# single-quoted $ is meant for the stubs and inner shells written here.
# shellcheck disable=SC2088,SC2016

set -uo pipefail

[ -d /src/.git ] || { echo "expected the repo mounted at /src" >&2; exit 2; }

# A writable copy of the repo stands in for GitHub, so pull/push can be
# exercised without touching the real remote. /src is owned by another uid.
git -c safe.directory='*' clone --quiet --bare \
  --branch "${DOTFILES_BRANCH:?}" /src /tmp/remote.git
export DOTFILES_REPO=/tmp/remote.git

# Stand-ins for downloads bootstrap skips when present (sudo and curl are
# recording stubs in the image). Keeps the test hermetic and fast. The mise
# stub records its calls too.
mkdir -p ~/.local/bin
printf '#!/bin/sh\n[ "$1" = install ] && echo "$*" >> /tmp/mise.calls\nexit 0\n' > ~/.local/bin/mise
chmod +x ~/.local/bin/mise
export PATH="/opt/stubs/bin:$PATH"

# shellcheck source=tests/lib.sh
. /src/tests/lib.sh

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

# No sudo/curl stubs on PATH, so bootstrap takes its install branches; curl is
# replaced by a recorder. A dry run must not download, create, or complain.
mkdir -p /tmp/rec /tmp/dryhome
printf '#!/bin/sh\necho "$*" >> /tmp/curl.calls\n' > /tmp/rec/curl
chmod +x /tmp/rec/curl
PATH=/tmp/rec:/usr/local/bin:/usr/bin:/bin \
  bash /src/bootstrap.sh --dry-run --with=cli,aws --home=/tmp/dryhome >/tmp/dry.out 2>/tmp/dry.err
check "dry run succeeds"              test $? -eq 0
check "dry run calls no curl"         test ! -e /tmp/curl.calls
check "dry run creates no files"      test -z "$(find /tmp/dryhome -mindepth 1)"
check "dry run prints no errors"      test ! -s /tmp/dry.err
check "dry run previews mise tools"   grep -q 'mise.* install' /tmp/dry.out
check "dry run previews apt packages" grep -q 'apt-get install .*tmux' /tmp/dry.out
check "dry run previews the SSM plugin" grep -q 'session-manager-plugin.deb' /tmp/dry.out
rm -f /tmp/curl.calls
[ ! -s /tmp/dry.err ] || sed 's/^/     | /' /tmp/dry.err

# ---- First run on a fresh home ----------------------------------------------

check "first run succeeds"            bootstrap --run
check "tracked files deployed, clean" test -z "$(config status --porcelain)"
check "skel .bashrc backed up"        cmp -s /etc/skel/.bashrc ~/.dotfiles-backup/.bashrc
check "core installs nothing" \
  test ! -e /tmp/sudo.calls -a ! -e /tmp/curl.calls -a ! -e /tmp/mise.calls
check "repo-only files stay out of \$HOME" \
  test ! -e ~/README.md -a ! -e ~/bootstrap.sh -a ! -e ~/tests
check "optional features stay out by default" \
  test ! -e ~/.aws -a ! -e ~/.bashrc.d/30-aws.sh -a ! -e ~/.bashrc.d/80-terraform.sh
check "config pull works"             config pull --quiet --ff-only
check "config push works (dry run)"   config push --quiet --dry-run

# ---- Re-run is a no-op ------------------------------------------------------

before=$(snapshot)
check "second run succeeds"           bootstrap --run
check "second run changes nothing"    test "$before" = "$(snapshot)"

# Clones made by older bootstraps have no refspec and no upstream.
config config --unset remote.origin.fetch
config branch --quiet --unset-upstream
check "re-run repairs an old clone"   bootstrap --run
check "  ...push works again"         config push --quiet --dry-run

# ---- Re-run with local changes ----------------------------------------------

echo '# local edit' >> ~/.bashrc
rm ~/.vimrc
check "re-run with local changes succeeds" bootstrap --run
check "  ...keeps the local edit"     grep -q '^# local edit$' ~/.bashrc
check "  ...keeps the deletion"       test ! -e ~/.vimrc
check "  ...names the changed files"  grep -q '\.vimrc' "$log"
config checkout -- .bashrc .vimrc

# ---- Re-run picks up new commits --------------------------------------------

git clone --quiet /tmp/remote.git /tmp/upstream-work
echo '" upstream change' >> /tmp/upstream-work/.vimrc
git -C /tmp/upstream-work -c user.name=t -c user.email=t@example.com \
  commit --quiet -am 'upstream change'
git -C /tmp/upstream-work push --quiet
check "re-run on a clean tree succeeds" bootstrap --run
check "  ...fast-forwards to origin"  grep -q '^" upstream change$' ~/.vimrc
check "  ...leaves the tree clean"    test -z "$(config status --porcelain)"

# ---- dotsync ----------------------------------------------------------------

# A commit left behind by a failed push; the tree itself is clean.
echo '" unpushed' >> ~/.vimrc
config -c user.name=t -c user.email=t@example.com commit --quiet -am 'unpushed'
bash -ic dotsync >/tmp/dotsync.out 2>&1
check "dotsync pushes earlier unpushed commits" \
  test "$(config rev-parse HEAD)" = "$(git -C /tmp/remote.git rev-parse HEAD)"

# ---- Optional features ------------------------------------------------------

check "unknown --with= feature is rejected" not bootstrap --run --with=nope
check "unknown --without= feature is rejected" not bootstrap --run --without=nope
check "--with=aws succeeds"           bootstrap --run --with=aws
check "  ...deploys its files" \
  test -f ~/.bashrc.d/30-aws.sh -a -f ~/.aws/cli/alias
check "  ...tree still clean"         test -z "$(config status --porcelain)"
check "plain re-run succeeds"         bootstrap --run
check "  ...remembers aws"            test -f ~/.bashrc.d/30-aws.sh
printf '[default]\n' > ~/.aws/config
check "--without=aws succeeds"        bootstrap --run --without=aws
check "  ...removes its tracked files" test ! -e ~/.bashrc.d/30-aws.sh -a ! -e ~/.aws/cli/alias
check "  ...keeps machine-local files" test -f ~/.aws/config
rm -rf ~/.aws

# A clone deployed before features existed has every file and no feature
# list; it must keep everything rather than lose a live ~/.aws.
config sparse-checkout disable 2>/dev/null
rm -f ~/.cfg/info/dotfiles-features
check "pre-features clone re-run succeeds" bootstrap --run
check "  ...keeps the feature files"  test -f ~/.bashrc.d/80-terraform.sh -a -f ~/.bashrc.d/30-aws.sh
check "  ...but drops repo-only files" test ! -e ~/README.md
check "--without=all back to core"    bootstrap --run --without=all
check "  ...feature files gone"       test ! -e ~/.bashrc.d/80-terraform.sh -a ! -e ~/.bashrc.d/30-aws.sh

# Each feature brings its own mise tool list; core has none.
mise_lists() { (cd ~/.config/mise/conf.d 2>/dev/null && ls) | tr '\n' ' '; }
check "core has no mise tool lists"   test -z "$(mise_lists)"
rm -f /tmp/sudo.calls /tmp/curl.calls /tmp/mise.calls
check "--with=cli,terraform succeeds" bootstrap --run --with=cli,terraform
check "  ...deploys exactly their lists" test "$(mise_lists)" = "cli.toml terraform.toml "
# bash-completion is already installed (as on stock Ubuntu): only tmux.
check "  ...apt-installs only what's missing (tmux)" \
  grep -q 'apt-get install -y --no-install-recommends tmux$' /tmp/sudo.calls
check "  ...runs mise install"         grep -qx install /tmp/mise.calls
rm -f /tmp/sudo.calls /tmp/curl.calls
check "--with=aws,containers succeeds" bootstrap --run --with=aws,containers
check "  ...apt-installs skopeo"       grep -q 'apt-get install .*skopeo' /tmp/sudo.calls
check "  ...with sudo -n (no terminal to type a password)" \
  grep -q '^-n apt-get install' /tmp/sudo.calls
check "  ...installs the SSM plugin .deb" \
  test -n "$(grep 'session-manager-plugin.deb' /tmp/curl.calls)" -a -n "$(grep 'dpkg -i' /tmp/sudo.calls)"
check "back to core" bootstrap --run --without=all

# cli wires fzf's key bindings into interactive shells (stub fzf).
printf '#!/bin/sh\n[ "$1" = --bash ] && echo "__fzf_stub_loaded() { :; }"\n' > ~/.local/bin/fzf
chmod +x ~/.local/bin/fzf
check "--with=cli deploys 70-fzf.sh"  bootstrap --run --with=cli
check "  ...and fzf's bindings load"  bash -ic 'declare -F __fzf_stub_loaded >/dev/null' 2>/dev/null
rm ~/.local/bin/fzf
check "  ...back to core"             bootstrap --run --without=cli
check "  ...70-fzf.sh removed"        test ! -e ~/.bashrc.d/70-fzf.sh
check "corp-ca outside WSL is only a notice" bootstrap --run --with=corp-ca
check "  ...pointing at ca-add"       grep -q 'ca-add' "$log"

# ---- Git identity -----------------------------------------------------------

personal=stevencwilkens@gmail.com
git init --quiet /tmp/elsewhere
check "commit outside known dirs is refused" \
  not git -C /tmp/elsewhere commit --quiet --allow-empty -m t
git init --quiet ~/personal/repo
check "~/personal uses the personal email" \
  test "$(git -C ~/personal/repo config user.email)" = "$personal"
check "dotfiles repo uses the personal email" \
  test "$(config config user.email)" = "$personal"
check "no ssh/URL rewrites for identity" \
  test -z "$(git -C ~/personal/repo config --get-regexp '^(core\.sshcommand|url\.)')"

# The work identity is machine-local so it never reaches the public repo.
check "~/.gitconfig-work is a local template" \
  test -f ~/.gitconfig-work -a -z "$(config ls-files .gitconfig-work)"
git init --quiet ~/work/repo
check "~/work refuses commits until the email is set" \
  not git -C ~/work/repo commit --quiet --allow-empty -m t
git config --file ~/.gitconfig-work user.email me@employer.example
check "~/work uses the work email once set" \
  test "$(git -C ~/work/repo config user.email)" = me@employer.example
check "closing notes ask for the work email while unset" \
  grep -q 'Set your work email' "$log"
check "  ...and say nothing about Windows on Linux" not grep -qi 'junction' "$log"
check "re-run keeps the edited template" bootstrap --run
check "  ...stops asking for the work email" not grep -q 'Set your work email' "$log"
check "  ...email still set" \
  test "$(git config --file ~/.gitconfig-work user.email)" = me@employer.example

# Per-machine settings: plain Linux gets an in-memory credential cache.
check "credential helper comes from ~/.gitconfig-local" \
  test "$(cd /tmp && git config --get credential.helper)" = 'cache --timeout=28800'
git config --file ~/.gitconfig-local credential.helper store
check "re-run keeps a changed helper" bootstrap --run
check "  ...helper still changed" \
  test "$(git config --file ~/.gitconfig-local credential.helper)" = store
check "  ...and explains SSH key setup" grep -q 'ssh-keygen' "$log"

# Dotfiles fetch anonymously over HTTPS and push over SSH once the personal
# key exists. insteadOf keeps the fetch local; only the URL string matters.
config remote set-url origin https://github.com/swilkens1/dotfiles.git
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url./tmp/remote.git.insteadOf \
  GIT_CONFIG_VALUE_0=https://github.com/swilkens1/dotfiles.git
check "no SSH push URL without the key" bootstrap --run
check "  ...pushurl unset" test -z "$(config config --get remote.origin.pushurl)"
touch ~/.ssh/id_ed25519_personal
check "re-run with the personal key succeeds" bootstrap --run
check "  ...pushes over SSH" \
  test "$(config config --get remote.origin.pushurl)" = git@github.com:swilkens1/dotfiles.git
check "  ...still fetches over HTTPS" \
  test "$(config config --get remote.origin.url)" = https://github.com/swilkens1/dotfiles.git
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
config remote set-url origin /tmp/remote.git
config config --unset remote.origin.pushurl
rm ~/.ssh/id_ed25519_personal

# ---- AWS helpers (sourced directly, against fixture files) ------------------

mkdir -p /tmp/awshome/.aws
cat > /tmp/awshome/.aws/config <<'EOF'
[default]
region = us-east-1
[profile dev]
sso_session = company
[sso-session company]
sso_region = us-east-1
[services internal]
s3 =
  endpoint_url = https://s3.internal.example
EOF
printf '[default]\naws_access_key_id = x\n[legacy]\naws_access_key_id = y\n' > /tmp/awshome/.aws/credentials
printf '[profile elsewhere]\r\n' > /tmp/alt-config      # CRLF, as written on Windows
aws_fn() { HOME=/tmp/awshome bash -c '. /src/.bashrc.d/30-aws.sh; '"$1" 2>&1; }

check "profiles: only real profiles, not sso-session/services" \
  test "$(aws_fn _aws_profiles | tr '\n' ' ')" = "default dev legacy "
check "profiles: honour AWS_CONFIG_FILE (and CRLF)" \
  test "$(AWS_CONFIG_FILE=/tmp/alt-config aws_fn _aws_profiles | tr '\n' ' ')" = "default elsewhere legacy "

check "aps -h prints usage"           aws_fn 'aps -h | grep -q "^Usage: aps"'
check "aps --help too"                aws_fn 'aps --help | grep -q "aps -u"'
check "aps PROFILE switches"          test "$(aws_fn 'aps dev; echo "$AWS_PROFILE"')" = dev
check "aps -u unsets"                 test "$(aws_fn 'aps dev; aps -u; echo "${AWS_PROFILE-unset}"')" = unset
check "aps rejects unknown profiles"  aws_fn '! aps nope 2>/dev/null'
check "aps rejects unknown options"   aws_fn 'aps -x 2>&1 >/dev/null | grep -q "unknown option"'
check "ssm names its missing prerequisites" \
  aws_fn '. /src/.bashrc.d/40-ssm.sh; ! ssm 2>/tmp/ssm.err && grep -q "ssm needs: aws fzf session-manager-plugin" /tmp/ssm.err'

# ---- Terraform helpers (stub aws/terraform, fixture repo) -------------------

mkdir -p /tmp/tfbin /tmp/tfrepo/accts /tmp/tfrepo/mod /tmp/tfcfg/dotfiles /tmp/backends
printf '#!/bin/sh\necho "${STUB_ACCT:-111111111111}"\n' > /tmp/tfbin/aws
printf '#!/bin/sh\necho "terraform $*" >> /tmp/terraform.calls\n' > /tmp/tfbin/terraform
chmod +x /tmp/tfbin/*
printf '# id  tfvars\n111111111111  staging.tfvars\n' > /tmp/tfcfg/dotfiles/tf-accounts
: > /tmp/backends/111111111111.hcl
git init --quiet /tmp/tfrepo
tf_fn() {
  (cd "${TF_DIR:-/tmp/tfrepo}" && PATH=/tmp/tfbin:$PATH XDG_CONFIG_HOME=/tmp/tfcfg \
    TF_BACKEND_DIR=/tmp/backends bash -c '. /src/.bashrc.d/80-terraform.sh; '"$1" 2>&1)
}
rm -f /tmp/terraform.calls
check "awsacct maps the account to its tfvars" \
  tf_fn 'awsacct | grep -q "tfvars  = accts/staging.tfvars"'
check "tfp plans with that tfvars, passing args through" \
  tf_fn 'tfp -target=x >/dev/null && grep -qx "terraform plan -var-file=accts/staging.tfvars -input=false -detailed-exitcode -target=x" /tmp/terraform.calls'
rm -f /tmp/terraform.calls
check "tfi inits with backend file and repo-named key" \
  tf_fn 'tfi >/dev/null && grep -qx "terraform init -backend-config=/tmp/backends/111111111111.hcl -backend-config=key=tfrepo/infra.tfstate" /tmp/terraform.calls'
check "  ...from a module dir, accts/ is found one level up" \
  env TF_DIR=/tmp/tfrepo/mod bash -c "$(declare -f tf_fn); tf_fn 'awsacct' | grep -q '../accts/staging.tfvars'"
rm -f /tmp/terraform.calls
check "unknown account stops before terraform runs" \
  env STUB_ACCT=999999999999 bash -c "$(declare -f tf_fn); ! tf_fn 'tfa -auto-approve' && test ! -e /tmp/terraform.calls"

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

agents() { grep -lx ssh-agent /proc/[0-9]*/comm 2>/dev/null | wc -l; }
agent_sock() { bash -ic 'echo "$SSH_AUTH_SOCK"; ssh-add -l >/dev/null 2>&1; echo $?' 2>/dev/null; }
out=$(agent_sock); out2=$(agent_sock)
check "shell gets an ssh-agent on a fixed socket" \
  test "$out" = "$HOME/.ssh/agent.sock"$'\n'1
check "  ...shared by later shells (agents: $(agents))" \
  test "$out2" = "$out" -a "$(agents)" -eq 1
# A dead agent leaves its socket behind (e.g. after a reboot).
kill -9 "$(grep -lx ssh-agent /proc/[0-9]*/comm | head -1 | cut -d/ -f3)"
check "  ...replaced when the old one died" test "$(agent_sock)" = "$out"
check "  ...still exactly one agent" test "$(agents)" -eq 1

ca_env() {
  bash -ic 'echo "${AWS_CA_BUNDLE:-unset} ${REQUESTS_CA_BUNDLE:-unset} ${NODE_EXTRA_CA_CERTS:-unset}"' 2>/dev/null
}
check "no CA variables on a stock machine" test "$(ca_env)" = "unset unset unset"
# The documented override, set in a local module that loads before 25-ca.sh.
: > /tmp/corp.pem
echo 'export CORP_CA_BUNDLE=/tmp/corp.pem' > ~/.bashrc.d/00-local.sh
check "CORP_CA_BUNDLE override reaches AWS, Python, Node" \
  test "$(ca_env)" = "/tmp/corp.pem /tmp/corp.pem /tmp/corp.pem"
rm ~/.bashrc.d/00-local.sh

check "completion library comes from the distro" \
  bash -ic 'declare -F _comp_initialize >/dev/null && [ ! -e "$XDG_DATA_HOME/bash-completion" ]'
check "no docker/kubectl/skopeo wrappers on Linux" \
  test -z "$(bash -ic 'for f in docker kubectl skopeo; do type -t $f; done' 2>/dev/null)"

check "TERM is kept inside tmux" \
  test "$(TERM=tmux-256color bash -ic 'echo "$TERM"' 2>/dev/null)" = tmux-256color
check "plain xterm gets 256 colors" \
  test "$(TERM=xterm bash -ic 'echo "$TERM"' 2>/dev/null)" = xterm-256color

summary
