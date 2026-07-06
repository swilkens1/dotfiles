# Git-aware prompt. Recomputes branch only when $PWD changes.

__prompt_git() {
  if [[ "$PWD" != "$LAST_PWD" || -z "$IN_GIT_REPO" ]]; then
    LAST_PWD="$PWD"
    if [[ -d .git ]] || git rev-parse --is-inside-work-tree &>/dev/null; then
      IN_GIT_REPO=1
    else
      IN_GIT_REPO=0
    fi
  fi
  if [[ "$IN_GIT_REPO" == "1" ]]; then
    GIT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null \
      || git rev-parse --short HEAD 2>/dev/null)
    GIT_BRANCH=" ($GIT_BRANCH)"
  else
    GIT_BRANCH=""
  fi
}

PROMPT_COMMAND=__prompt_git

PS1='\[\e]0;\w\a\]\n\
\[\e[32m\]swilkens@\h \
\[\e[35m\]\w\
\[\e[36m\]${GIT_BRANCH}\
\[\e[0m\]\n$ '
