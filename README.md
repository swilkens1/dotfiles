# dotfiles

Bare-repo dotfiles for bash, git, vim and the AWS CLI, managing `$HOME`
directly. Built for:

- **Linux and WSL** (Ubuntu/Debian first) — the main target
- **Windows Git Bash** — kept working

A default bootstrap is minimal: shell, git and vim config, nothing installed.
Everything else is an opt-in feature.

## Bootstrap a new machine

Prerequisites: `git`, `curl` and `bash` (all stock on Ubuntu). On Windows,
install Git for Windows and use **Git Bash**.

```bash
curl -fsSL https://raw.githubusercontent.com/swilkens1/dotfiles/master/bootstrap.sh -o ~/bootstrap.sh
bash ~/bootstrap.sh --run                                   # core only
bash ~/bootstrap.sh --run --with=cli,aws,terraform          # or pick features
```

**WSL behind a TLS-inspecting corporate proxy:** Linux's `curl` won't trust the
proxy yet. Use Windows' `curl.exe` (it trusts the Windows certificate store)
and let bootstrap fix trust before it clones anything — no `curl -k`:

```bash
/mnt/c/Windows/System32/curl.exe -fsSL https://raw.githubusercontent.com/swilkens1/dotfiles/master/bootstrap.sh > ~/bootstrap.sh
bash ~/bootstrap.sh --run --with=corp-ca,cli
```

Then follow the short "Next steps" list bootstrap prints; it shows only what
still applies to this machine.

### Features

| Feature | Deploys | Installs |
|---|---|---|
| *(core)* | shell modules, `.gitconfig*`, `.vimrc`, `ca-add` | nothing |
| `cli` | `70-fzf.sh`, `conf.d/cli.toml` | apt: tmux, bash-completion · mise: fzf, ripgrep, jq, bat, fd, delta, neovim, shellcheck, usage |
| `aws` | `30-aws.sh`, `40-ssm.sh`, `.aws/cli/alias`, `conf.d/aws.toml` | mise: aws-cli · AWS's Session Manager plugin `.deb` |
| `terraform` | `80-terraform.sh`, `conf.d/terraform.toml` | mise: terraform, tflint, terraform-ls, trivy, terraform-docs |
| `containers` | `conf.d/containers.toml` | apt: skopeo · mise: kubectl |
| `corp-ca` | — | WSL: `sync-windows-ca` + boot hook (see [Corporate CA](#corporate-ca)) |
| `windows-apps` | — | Git Bash: Git, Docker Desktop, Multipass, VS Code (winget) |

On Git Bash, Scoop provides the `cli` tools and winget the AWS CLI and plugin;
mise still provides shellcheck, usage, the terraform tools and kubectl.

### Flags

- `--run` executes; with no flags the script prints help and exits, so a
  stray double-click or `curl | bash` does nothing.
- `--dry-run` prints every action without doing anything (no downloads, no
  files). Combine with `--home=PATH` for a scratch home.
- `--with=LIST` / `--without=LIST` add or remove features (`all` works). The
  selection is saved in `~/.cfg/info/dotfiles-features`; a plain re-run keeps it.
- `DOTFILES_REPO` / `DOTFILES_BRANCH` choose the clone source and branch (a
  local path works — handy for testing a branch).

Installs that need root use `sudo`. Without a terminal (`--run </dev/null`)
bootstrap uses `sudo -n`, so a missing password fails at once with an
"install by hand" warning instead of waiting.

### Re-running is safe

A re-run with the same arguments changes nothing. It also:

- fast-forwards to new commits on origin when the tracked files are clean;
- leaves modified or deleted tracked files alone and lists them;
- adds or removes a feature's files when the selection changes, never
  deleting a modified file;
- seeds machine-local files (`~/.gitconfig-work`, `~/.gitconfig-local`, …)
  only when missing, and never overwrites them;
- installs only packages and tools that are missing, and skips sudo when
  there's nothing to install.

The first deploy backs up any pre-existing file it replaces to
`~/.dotfiles-backup/`.

## Daily workflow

```bash
config status                       # tracked changes
config add -f ~/path/to/new/file    # track a new file (-f: info/exclude is "*")
dotsync                             # pull, show changes, commit (editor), push
dotsync -m "message"                # same, one-line message
```

`config` is `git --git-dir=$HOME/.cfg/ --work-tree=$HOME`. Nothing is tracked
by accident: `info/exclude` holds `*`. Only the selected features' files are
in `$HOME` (a sparse checkout), so adding a file under an *unselected*
feature's path needs `config add -f --sparse`. `dotsync` also pushes commits
left behind by an earlier failed push.

The dotfiles repo fetches over anonymous HTTPS; once
`~/.ssh/id_ed25519_personal` exists, bootstrap sets the push URL to SSH.

## Machine-local, never tracked

| File | What goes there |
|---|---|
| `~/.gitconfig-work` | work email (commits under `~/work/` fail until set), optional `insteadOf` for the work Git host |
| `~/.gitconfig-local` | credential helper (seeded per platform), per-host `sslCAInfo`, proxies |
| `~/.ssh/config`, keys | per-host keys (bootstrap prints a template) |
| `~/.bashrc.d/00-*.sh` | early overrides, e.g. `export CORP_CA_BUNDLE=…` |
| `~/.bashrc.d/9*.sh` | late overrides and machine-specific additions |
| `~/.config/dotfiles/tf-accounts` | `ACCOUNT_ID TFVARS_FILE` pairs for the terraform helpers |
| `~/.aws/config`, `credentials`, `sso/`, `cli/cache/` | AWS profiles and tokens |
| `~/.claude/`, `~/.claude.json` | Claude Code settings and state, kept per machine |

`bootstrap.sh` writes `info/exclude` with explicit entries for these as a
second guard, but `config add -f` overrides any exclude — don't force-add them.

## What's tracked

| Path | Purpose |
|---|---|
| `.bash_profile` | login shell: `.profile`, then `.bashrc` unless `.profile` already loaded it (Ubuntu's does) |
| `.bashrc` | interactive shells: vi mode, loads `~/.bashrc.d/*.sh` in order |
| `.bashrc.d/10-prompt.sh` | prompt with git branch |
| `.bashrc.d/15-ssh-agent.sh` | one ssh-agent per user on `~/.ssh/agent.sock`, shared by all shells |
| `.bashrc.d/20-platform.sh` | XDG dirs; Git Bash: Scoop PATH, `DOCKER_CONFIG`/`KUBECONFIG`, path-conversion wrappers, containerised skopeo |
| `.bashrc.d/25-ca.sh` | points the AWS CLI, Python and Node at a bundle with the corporate CA |
| `.bashrc.d/30-aws.sh` | `aps` profile switcher (`aps -h`), `awsi`, `awshelp`, completion · aws |
| `.bashrc.d/40-ssm.sh` | `ssm [filter]`: pick a running instance, start a session · aws |
| `.bashrc.d/50-dotsync.sh` | `config` alias, `dotsync` |
| `.bashrc.d/60-mise.sh` | `~/.local/bin` on PATH, mise activation (shims on Git Bash) |
| `.bashrc.d/70-completions.sh` | bash-completion plus cached kubectl/docker/gh/helm/mise completions |
| `.bashrc.d/70-fzf.sh` | fzf key bindings and `**` completion · cli |
| `.bashrc.d/80-terraform.sh` | `awsacct`, `tfi`, `tfp`, `tfa` · terraform |
| `.config/mise/config.toml`, `conf.d/*.toml` | mise tools, one file per feature |
| `.gitconfig`, `.gitconfig-personal` | shared git config; personal identity |
| `.vimrc` | vim-plug, gruvbox, ALE, fugitive, tmux-navigator, Terraform |
| `.aws/cli/alias` | `aws whoami`, `aws regions`, `aws running` · aws |
| `.local/bin/ca-add` | trust a CA certificate system-wide (Linux) |
| `.local/bin/extract-corp-ca` | export a CA from the Windows store (Git Bash) |
| `bootstrap.sh`, `README.md`, `tests/` | repo only — never deployed to `$HOME` |

## Git identity and SSH

- **No default email.** `user.useConfigOnly` makes git refuse to commit
  outside `~/personal/` (personal), `~/work/` (work) and the dotfiles repo
  (personal), instead of guessing.
- **Keys are chosen per host** in `~/.ssh/config` (`IdentitiesOnly yes`, so
  the agent can't offer the wrong key). No host aliases or URL rewrites.
  If a network blocks port 22, use `Hostname ssh.github.com` / `Port 443`.
- **HTTPS still works.** On WSL the credential helper is Windows' Git
  Credential Manager, so tokens live in the Windows credential store; on Git
  Bash it's `manager`; elsewhere an 8-hour memory cache. CodeCommit uses the
  AWS CLI helper.

## Corporate CA

The goal: once, per machine, make the OS trust the proxy's CA; everything
else follows from the OS trust store.

- **WSL:** `--with=corp-ca` installs `/usr/local/sbin/sync-windows-ca`,
  which copies the Windows root CAs into the Linux store, and registers it as
  the `[boot]` command in `/etc/wsl.conf` (merged into an existing `[boot]`;
  someone else's command is never replaced). At boot it waits in the
  background for Windows interop, so a rotated proxy CA arrives by itself.
  Run it by hand with `sudo sync-windows-ca`; boot results are in
  `journalctl -t sync-windows-ca`. Works on Windows 10 too.
- **Other Linux, or one internal host** (an internal GitLab, say) whose CA
  isn't in the Windows store: `ca-add FILE [NAME]`; `ca-add --list`.
- **Git Bash:** no Linux store to extend. `extract-corp-ca` writes the CA to
  `~/.local/share/corp-ca.cer` for the AWS CLI; for git, set
  `http.<url>.sslCAInfo` in `~/.gitconfig-local`.

`25-ca.sh` then points tools with their own CA lists (AWS CLI, Python
requests, Node) at the system bundle. Override with `CORP_CA_BUNDLE` in a
local `~/.bashrc.d/00-*.sh`.

## Tools and versions (mise)

Each feature brings its tool list as `~/.config/mise/conf.d/<feature>.toml`;
`mise use -g TOOL` adds to `config.toml` — commit it with `dotsync`. Versions
float (`latest`); pin in a project with `mise use terraform@1.9.5`.

```bash
mise install        # install everything configured
mise outdated       # what's behind latest
mise upgrade        # move floating versions forward
mise self-update    # upgrade mise itself (bootstrap installs MISE_VERSION)
```

Inside a *checkout* of this repo (as opposed to `$HOME`), mise sees the
repo's `.config/mise/` as untrusted project config and prints errors; run
`mise trust --ignore` there once.

## Git Bash specifics

Git Bash can use a `HOME` other than `%USERPROFILE%` (e.g. `C:\DevOpsHome`).
Windows-native tools still look in `%USERPROFILE%`, so:

1. **Env-var redirects** in `20-platform.sh` / `60-mise.sh`: `DOCKER_CONFIG`,
   `KUBECONFIG`, `XDG_*`, `MISE_CONFIG_DIR` (not `MISE_GLOBAL_CONFIG_FILE`,
   which ignores `conf.d/`).
2. **NTFS junctions** made by bootstrap for tools with no override: `.ssh`,
   plus `.aws` (aws).

**Never `rm -rf` a junction** — bash follows it and deletes the target. Remove
just the junction with `cmd //c rmdir "$(cygpath -w ~/.aws)"`.

## Testing

```bash
tests/run.sh                                  # Docker; needs a committed branch
TEST_CA_BUNDLE=~/corp-ca.pem tests/run.sh     # behind a TLS-inspecting proxy
bash bootstrap.sh --dry-run --home=/tmp/fake-home --with=all
```

`tests/run.sh` builds an `ubuntu:26.04` image and runs two containers:
`assert.sh` as a normal user (first deploy, re-run idempotency, features,
git identity, shell startup, helpers) and `assert-root.sh` as root
(`sync-windows-ca` with a fake `powershell.exe`, the wsl.conf merge,
`ca-add`). It deploys the committed HEAD of the current branch from a local
stand-in remote, with sudo, curl and mise replaced by recorders — no network,
no root on the host. Git Bash and real package installs need a real machine:
use `--dry-run` there, then a real run.

ShellCheck without installing it:
`docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x bootstrap.sh .bashrc.d/*.sh`

## Adding shell modules

Drop `NN-name.sh` in `~/.bashrc.d/`; they load in order:

- `00`–`09`: local, untracked, early (inputs for later modules)
- `10`–`19`: prompt, shell behaviour, ssh-agent
- `20`–`29`: platform, CA environment
- `30`–`49`: AWS, SSM
- `50`–`59`: dotfiles management
- `60`–`69`: mise
- `70`–`79`: completions, fzf
- `80`–`89`: terraform
- `90`+: local, untracked, late overrides

Then `config add -f ~/.bashrc.d/NN-name.sh && dotsync`. If it belongs to a
feature, add its path to `excluded_paths()` in `bootstrap.sh`.

## Switching to Neovim later

Create `~/.config/nvim/init.vim` (Windows: `~/AppData/Local/nvim/init.vim`):

```vim
set runtimepath^=~/.vim runtimepath+=~/.vim/after
let &packpath = &runtimepath
source ~/.vimrc
```

## Forking

Set `DOTFILES_REPO` (or change the default in `bootstrap.sh`) and the
identity in `.gitconfig` / `.gitconfig-personal`.
