# dotfiles

Bare-repo dotfiles for bash, vim, git, AWS CLI, and Claude Code CLI. Runs on:

- **Windows** — Git Bash (bundled with Git for Windows)
- **Linux** — any bash-capable distro
- **macOS** — bash

## Bootstrap a new machine

Prereqs:
- **Windows**: install Git for Windows first (`winget install Git.Git`), then launch **Git Bash**.
- **Linux/macOS**: `git`, `curl`, `bash`, `vim` on PATH.

```bash
curl -fsSL https://raw.githubusercontent.com/swilkens1/dotfiles/master/bootstrap.sh \
  -o ~/bootstrap.sh
bash ~/bootstrap.sh --run
```

`bootstrap.sh` without a flag prints its help and exits — so accidental invocations (double-click, `curl … | bash`) are a no-op. Explicit `--run` is required to execute. Other flags:

- `--dry-run` — print every action without executing.
- `--home=PATH` — run against `PATH` instead of your real `$HOME` (sandboxed test mode). Combine with `--dry-run` for a hermetic sanity check.

Then complete the manual steps the script prints (corp CA if applicable, `aws configure sso`, work email in `.gitconfig-work`).

## Daily workflow

```bash
config status                       # see tracked changes
config add -f ~/path/to/new/file    # start tracking a new file (-f required: info/exclude=*)
dotsync                             # pull, show diff, commit, push
```

`config` is an alias for `git --git-dir=$HOME/.cfg/ --work-tree=$HOME`. The `*` in `info/exclude` means nothing is auto-tracked — you must explicitly `-f` add every new file. `bootstrap.sh` re-creates `info/exclude` with an explicit deny list on top of `*`.

## What's tracked

| File | Purpose |
|---|---|
| `.bash_profile` | Sources `.bashrc`, starts `ssh-agent` |
| `.bashrc` | Thin loader — sources `~/.bashrc.d/*.sh` |
| `.bashrc.d/10-prompt.sh` | Git-aware prompt |
| `.bashrc.d/20-platform.sh` | Scoop/brew PATH, XDG dirs, `DOCKER_CONFIG`/`KUBECONFIG`, MSYS path-conv wrappers |
| `.bashrc.d/30-aws.sh` | `AWS_CA_BUNDLE`, `aps` profile switcher, completions |
| `.bashrc.d/40-ssm.sh` | `ssm [filter]` — interactive EC2 SSM session starter |
| `.bashrc.d/50-dotsync.sh` | `config` alias + `dotsync` function |
| `.bashrc.d/60-mise.sh` | Adds `~/.local/bin` to PATH, activates mise |
| `.bashrc.d/70-fzf.sh` | Sources fzf keybindings + completion |
| `.bashrc.d/80-terraform.sh` | tf helpers (`awsacct`, `tfi`, `tfp`, `tfa`) |
| `.config/mise/config.toml` | Global mise tool list — bootstrap hydrates from this |
| `.gitconfig` | Identity, `includeIf` for `personal/` and `work/` dirs, CodeCommit helper |
| `.gitconfig-personal` | Personal identity + `git@github.com-personal:` URL rewrite |
| `.gitconfig-work` | Work identity template (`email = [FILL]`) |
| `.vimrc` | vim-plug + gruvbox + ALE + fugitive + tmux-navigator |
| `.aws/cli/alias` | AWS CLI subcommand aliases (`aws whoami`, `aws running`, …) |
| `.claude/settings.json` | Claude Code CLI config — effort level, hooks wiring |
| `.claude/hooks/archive-session.sh` | Copies each session transcript to `$CLAUDE_ARCHIVE_DIR` |
| `.claude/hooks/check-archive-size.sh` | Warns when archive dir exceeds 500 MB |
| `bootstrap.sh` | This file's setup script |
| `tests/` | Docker-based end-to-end test |
| `certs/` | Optional corp CA bundle for the test container (empty by default) |
| `README.md` | This file |

## What's deliberately NOT tracked

- `.aws/config`, `.aws/credentials`, `.aws/sso/`, `.aws/cli/cache/` — per-machine SSO / creds / caches
- `.local/share/corp-ca.cer` — corporate CA bundle, per-machine
- `~/.ssh/` — generate fresh keys per machine
- `.claude.json` — per-machine state (machineID, userID, onboarding flags)
- `.claude/settings.local.json` — machine-specific overrides (e.g., `CLAUDE_CODE_GIT_BASH_PATH`)
- `.claude/auth.conf` — employer-managed SSO config
- `.claude/{sessions,projects,cache,backups,shell-snapshots,ide,session-env,file-history}/` — runtime state

Since `info/exclude=*` is deny-by-default, the above just documents things that *look* trackable but shouldn't be. `bootstrap.sh` re-writes `info/exclude` with the same explicit denies.

## Portable HOME on Windows

Git Bash uses `$HOME` = `%USERPROFILE%` by default, but you can move `$HOME` elsewhere (e.g., `C:\DevOpsHome`) by setting a `HOME` user environment variable and updating the Git Bash shortcut's "Start in" field. Once moved, Windows-native tools that resolve home via `%USERPROFILE%` will see a different directory than the shell. Two mechanisms bring them back in line:

1. **Env-var redirects** (`~/.bashrc.d/20-platform.sh`): `DOCKER_CONFIG`, `KUBECONFIG`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`. Docker, kubectl, mise, and every XDG-aware tool now honor `$HOME`.
2. **NTFS junctions** (`bootstrap.sh` creates these): `.aws`, `.claude`, `.ssh` — the consumers of these dirs (aws.exe's alias file, `claude.exe`, Windows-native OpenSSH, VS Code Remote-SSH) hardcode `%USERPROFILE%` and have no env-var override.

Junctions need no Admin rights or Developer Mode. To rollback:

```bash
cmd //c rmdir "$(cygpath -w ~/.claude)"     # removes the junction; target untouched
```

**Never** `rm -rf` a junction from bash — it follows the link and deletes the target.

## Cross-platform tool install strategy

| Category | Windows | Linux | macOS |
|---|---|---|---|
| Language runtimes / IaC (terraform, kubectl, tflint, node, python, …) | **mise** | mise | mise |
| CLI comforts (tmux, ripgrep, fzf, neovim, jq, bat, fd, delta) | **scoop** | **linuxbrew** | **brew** |
| Git, AWS CLI, SSM plugin | winget | linuxbrew | brew |
| Docker Desktop / Engine | winget | manual (Docker Engine) | brew `--cask` |
| Multipass | winget | `snap install multipass` | brew `--cask` |
| VS Code | winget | manual / snap | brew `--cask` |

Bootstrap installs scoop on Windows and Homebrew on Linux/macOS on first run. `~/scoop/shims` and `brew shellenv` are added to PATH in `~/.bashrc.d/20-platform.sh`.

**Gotchas:**
- Windows tmux from scoop is a real Cygwin build — works inside Git Bash but has quirks around 256-color detection.
- linuxbrew is ~1 GB and its first `brew install` triggers a compiler pull; expect the first bootstrap on Linux to take 10+ minutes.
- On a corp MITM'd network, both scoop and brew need `SSL_CERT_FILE` (or the OS trust store to already contain the corp CA). See "Corporate machines" below.

## Corporate machines

If your work machine sits behind a corporate MITM proxy:

1. **Filename convention:** drop the cert at `~/.local/share/corp-ca.cer`. `30-aws.sh` finds it and exports `AWS_CA_BUNDLE`.
2. **Env-var override:** export `CORP_CA_BUNDLE=/some/path` from a local-only `~/.bashrc.d/9*.sh`.

The corp CA file is not tracked. For the Docker test to work on a corp network, drop the same cert (as `<name>.crt`) at `certs/` in the repo — `certs/.gitignore` prevents anything but `.gitkeep` from being committed. Bootstrap doesn't install the CA into the Windows/macOS system trust store — do that once by hand.

## Claude Code

Claude Code CLI and the VS Code extension resolve their config dir from `%USERPROFILE%\.claude` on Windows regardless of `$HOME`. `bootstrap.sh` junctions `$HOME/.claude` → `%USERPROFILE%\.claude` so tracked files (`settings.json`, `hooks/*.sh`) sync correctly through the repo.

### settings.local.json — machine-specific escape hatch

Claude Code merges `settings.local.json` on top of `settings.json`. Common Windows use:

```json
{
  "env": {
    "CLAUDE_CODE_GIT_BASH_PATH": "C:\\Program Files\\Git\\bin\\bash.exe"
  }
}
```

Only set this if Claude Code isn't auto-detecting Git Bash. Restart Claude Code after editing — env vars load at startup.

### Hooks

- `SessionStart` → `check-archive-size.sh` (warns if `~/claude-archive` > 500 MB)
- `SessionEnd` → `archive-session.sh` (copies the session's `.jsonl` transcript there)

Both honor `$CLAUDE_ARCHIVE_DIR` — export it from a local-only `~/.bashrc.d/9*.sh` to move the archive.

### VS Code sync

Use VS Code's built-in Settings Sync (sign in with GitHub/MS) for VS Code's own `settings.json`, keybindings, extensions, snippets. Don't try to track `%APPDATA%\Code\User\` in this repo — no overlap and less to manage.

## Testing bootstrap

Two mechanisms, use both:

### Sandboxed HOME (all OSes, no side effects)

```bash
mkdir -p /tmp/fake-home
bash bootstrap.sh --home=/tmp/fake-home --dry-run
```

Prints every action against a scratch HOME without touching your real `$HOME` or installing anything. Useful for verifying logic changes on Windows where Docker can't exercise the scoop/winget paths.

### Docker end-to-end (Linux path)

```bash
tests/run.sh
```

Builds an Ubuntu container, runs `bootstrap.sh --run` inside it for real, and runs `tests/assert.sh` to verify the resulting home layout. Takes several minutes on first run (Homebrew install). Rerun after any change to `bootstrap.sh`.

Windows scoop/winget paths can't be exercised by Docker. For those: `--dry-run` on the host for logic checks, then a real run on a spare box or Multipass VM.

## Adding new modules

Drop a file in `~/.bashrc.d/` using the load-order prefix:

- `10`–`19`: prompt / shell behavior
- `20`–`29`: platform / OS wrappers
- `30`–`39`: AWS
- `40`–`49`: SSM / per-tool helpers
- `50`–`59`: dotfiles management
- `60`–`69`: tool / version managers (mise)
- `70`–`79`: shell integrations (fzf, direnv, …)
- `80`–`89`: terraform
- `90`+: local-only overrides (not tracked)

Then: `config add -f ~/.bashrc.d/NN-name.sh && dotsync`.

## Managing tool versions (mise)

`bootstrap.sh` installs mise into `~/.local/bin` and hydrates from `~/.config/mise/config.toml`. On Windows it pulls the raw `.exe` from GitHub releases (corporate AV can block winget's extract).

```bash
mise use -g terraform@latest tflint@latest    # set + install globals
mise use terraform@1.9.5                      # pin in current project (creates .mise.toml)
mise install                                  # install everything from config(s)
mise upgrade                                  # bump floating pins
mise outdated                                 # show what's behind latest
mise self-update                              # upgrade mise itself
```

Linux/macOS: `60-mise.sh` runs `eval "$(mise activate bash)"` so a `cd` swaps versions on the next prompt. Windows: shim mode (mise's `activate bash` output is Windows-format PATH bash can't parse).

When you change globals, commit them: `config add -f ~/.config/mise/config.toml && dotsync`.

## Switching to Neovim later

Create `~/AppData/Local/nvim/init.vim` (Windows) or `~/.config/nvim/init.vim` (Linux) with:

```vim
set runtimepath^=~/.vim runtimepath+=~/.vim/after
let &packpath = &runtimepath
source ~/.vimrc
```

Nvim then reuses your existing `.vimrc` and plugins as-is. Port to `init.lua` + lazy.nvim incrementally from there.

## Contributing / forking

Bootstrap resolves the repo URL from `$DOTFILES_REPO` if set, otherwise from the hardcoded default in `bootstrap.sh`. Fork this repo, change your fork's URL there, and the one-liner Just Works.
