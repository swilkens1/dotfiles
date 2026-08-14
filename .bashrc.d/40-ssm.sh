# Interactive SSM session starter.
# Usage:
#   ssm              # filter instances containing "bas" in Name tag
#   ssm web          # filter instances containing "web" in Name tag
# Requires aps() and _aws_profiles() from 30-aws.sh.

ssm() {
  local RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'

  if [ -z "${AWS_PROFILE:-}" ]; then
    local p
    p=$(_aws_profiles | fzf --height=20% --reverse \
          --header='AWS profile  (Esc cancels)') || return 1
    [ -n "$p" ] || { echo -e "${YELLOW}Cancelled${NC}"; return 1; }
    aps "$p" || return 1
  fi
  echo -e "${GREEN}Profile: ${AWS_PROFILE}${NC}"

  if ! aws sts get-caller-identity &>/dev/null; then
    echo -e "${YELLOW}SSO login required...${NC}"
    aws sso login || { echo -e "${RED}SSO login failed${NC}"; return 1; }
  fi

  # $1 seeds fzf's query rather than hard-filtering, so a typo just means an
  # empty list you can backspace out of instead of "no instances found".
  # --with-nth reorders the *display* to name-first; the returned line is
  # still the full tab-separated record.
  local sel
  sel=$(aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running" \
    --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`]|[0].Value,State.Name]' \
    --output text \
    | fzf --query="${1:-bas}" --height=40% --reverse \
          --with-nth=2,1,3 --header='Select instance  (Esc cancels)') || return 1

  if [ -z "$sel" ]; then
    echo -e "${RED}No instance selected${NC}"
    return 1
  fi

  local sid sname
  IFS=$'\t' read -r sid sname _ <<< "$sel"
  echo -en "\n${YELLOW}Auto-reconnect on disconnect? (y/N): ${NC}"
  local r
  read -r r

  if [[ "$r" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Auto-reconnect enabled. Ctrl+C twice to exit.${NC}"
    while true; do
      echo -e "${GREEN}Connecting to $sname ($sid)${NC}"
      aws ssm start-session --target "$sid"
      [ $? -eq 130 ] && break
      echo -e "${YELLOW}Disconnected. Reconnecting in 3s (Ctrl+C to exit)...${NC}"
      sleep 3
    done
  else
    echo -e "${GREEN}Connecting to $sname ($sid)${NC}"
    aws ssm start-session --target "$sid"
  fi
}
