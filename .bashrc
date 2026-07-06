# If not running interactively, don't do anything
[[ "$-" != *i* ]] && return

set -o vi
export TERM=xterm-256color

# Source modular config in lexicographic order: 10-* before 20-*, etc.
# Use multiples of 10 so new modules can slot in between (15-foo.sh)
# without renaming neighbors.
if [ -d "$HOME/.bashrc.d" ]; then
  for rc in "$HOME"/.bashrc.d/*.sh; do
    [ -r "$rc" ] && . "$rc"
  done
  unset rc
fi

## ----- TF helpers for now ----- ##
alias tf="terraform"

export backend_path=~/work/backends

awsacct () {
    unset acct
    acct=$(aws sts get-caller-identity | jq -r .Account)
    printf '%-15s= %s\n' "acct" $acct
    accts=$(find . -maxdepth 1 -type d -name 'accts')
    # Need to make files for each env
    if [[ "$accts" == "./accts" ]]; then
        accts="accts"
    else
        accts="../accts"
    fi
    if [[ "$acct" == "307376763236" ]]; then
        tfvars="govpre.tfvars"
    elif [[ "$acct" == "143547515652" ]]; then
        tfvars="govprod.tfvars"
    elif [[ "$acct" == "134803128024" ]]; then
        tfvars="dod.tfvars"
    elif [[ "$acct" == "812010445813" ]]; then
        tfvars="staging_pre.tfvars"
    elif [[ "$acct" == "011535922801" ]]; then
        tfvars="staging_prod.tfvars"
    else
        echo account not configured
        return 0
    fi

    printf '%-15s= %s\n' "tfvars" $accts/$tfvars
}

tfi () {
    awsacct
    backend_file=$(cygpath -w "$backend_path/$acct.hcl")

    # accts=$(find . -maxdepth 1 -type d -name 'accts')
    # if [[ "$accts" == "accts" ]]; then
        # backend_key="key=$(basename $(pwd))/infra.tfstate"
    # else
        # backend_key="key=$(basename $(dirname $(pwd)))/infra.tfstate"
    # fi
    backend_key="key=$(basename $(git rev-parse --show-toplevel))/infra.tfstate"
    printf '%-15s= %s\n' "backend_file" "$backend_file" "backend_key" "$backend_key"
    tf init -backend-config="$backend_file" -backend-config="$backend_key" "$1"
}

tfp () {
    awsacct
    tf plan -var-file=$(cygpath -w $accts/$tfvars) -input=false -detailed-exitcode "$1"
}

tfa () {
    awsacct
    printf "applying...\n"
    if [[ "$1" == "-auto-approve" ]]; then
        echo auto-approve
    fi
    tf apply -var-file=$(cygpath -w $accts/$tfvars) $1
}

