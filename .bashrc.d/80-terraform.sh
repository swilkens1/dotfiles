# shellcheck shell=bash
# Terraform helpers for repos that keep one tfvars file per AWS account
# (--with=terraform).
#
#   awsacct      show the current AWS account and its tfvars file
#   tfi [ARGS]   terraform init  with that account's backend config
#   tfp [ARGS]   terraform plan  -var-file=<tfvars> -input=false -detailed-exitcode
#   tfa [ARGS]   terraform apply -var-file=<tfvars>
#
# Expected layout, run from a repo or module directory:
#   accts/ or ../accts/                tfvars files
#   $TF_BACKEND_DIR/<account-id>.hcl   backend config (default ~/work/backends)
# with the state key <repo name>/infra.tfstate.
#
# Which tfvars file goes with which account is machine-local -- account IDs
# stay out of the public repo. One "ACCOUNT_ID TFVARS_FILE" pair per line
# (# comments allowed) in $TF_ACCOUNTS_FILE, default
# ~/.config/dotfiles/tf-accounts:
#   123456789012  staging.tfvars

alias tf=terraform

TF_BACKEND_DIR="${TF_BACKEND_DIR:-$HOME/work/backends}"
TF_ACCOUNTS_FILE="${TF_ACCOUNTS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/tf-accounts}"

# terraform.exe on Git Bash wants Windows paths.
_tf_native_path() {
  case "$OSTYPE" in
    msys*|cygwin*) cygpath -w "$1" ;;
    *)             printf '%s\n' "$1" ;;
  esac
}

# Sets _tf_acct and _tf_tfvars for the current credentials, or fails with a
# reason. Both are reset first, so a failure never leaves stale values.
_tf_account() {
  _tf_acct="" _tf_tfvars=""
  local file dir
  _tf_acct=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
  if [ -z "$_tf_acct" ]; then
    echo "awsacct: no AWS credentials (aps PROFILE, then aws sso login)" >&2
    return 1
  fi
  file=$(awk -v a="$_tf_acct" '!/^[[:space:]]*#/ && $1 == a { print $2; exit }' \
    "$TF_ACCOUNTS_FILE" 2>/dev/null)
  if [ -z "$file" ]; then
    echo "awsacct: account $_tf_acct is not in $TF_ACCOUNTS_FILE" >&2
    return 1
  fi
  for dir in accts ../accts; do
    if [ -d "$dir" ]; then
      _tf_tfvars="$dir/$file"
      break
    fi
  done
  if [ -z "$_tf_tfvars" ]; then
    echo "awsacct: no accts/ directory here or one level up" >&2
    return 1
  fi
}

awsacct() {
  _tf_account || return 1
  printf '%-8s= %s\n' acct "$_tf_acct" tfvars "$_tf_tfvars"
}

tfi() {
  awsacct || return 1
  local top backend key
  top=$(git rev-parse --show-toplevel 2>/dev/null) ||
    { echo "tfi: not inside a git repository" >&2; return 1; }
  backend="$TF_BACKEND_DIR/$_tf_acct.hcl"
  [ -f "$backend" ] || { echo "tfi: no backend config at $backend" >&2; return 1; }
  key="key=$(basename "$top")/infra.tfstate"
  printf '%-8s= %s\n' backend "$backend" key "${key#key=}"
  terraform init -backend-config="$(_tf_native_path "$backend")" -backend-config="$key" "$@"
}

tfp() {
  awsacct || return 1
  terraform plan -var-file="$(_tf_native_path "$_tf_tfvars")" -input=false -detailed-exitcode "$@"
}

tfa() {
  awsacct || return 1
  terraform apply -var-file="$(_tf_native_path "$_tf_tfvars")" "$@"
}
