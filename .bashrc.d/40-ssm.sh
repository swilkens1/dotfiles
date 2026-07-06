# Interactive SSM session starter.
# Usage:
#   ssm              # filter instances containing "bas" in Name tag
#   ssm web          # filter instances containing "web" in Name tag
# Requires aps() and _aws_profiles() from 30-aws.sh.

ssm() {
  local RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'

  if [ -z "${AWS_PROFILE:-}" ]; then
    echo -e "${YELLOW}Select AWS profile:${NC}"
    local p
    select p in $(_aws_profiles); do
      [ -n "$p" ] && aps "$p" && break
    done
  fi
  echo -e "${GREEN}Profile: ${AWS_PROFILE}${NC}"

  if ! aws sts get-caller-identity &>/dev/null; then
    echo -e "${YELLOW}SSO login required...${NC}"
    aws sso login || { echo -e "${RED}SSO login failed${NC}"; return 1; }
  fi

  local filter="${1:-bas}"
  local instances
  instances=$(aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running" \
    --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`]|[0].Value,State.Name]' \
    --output text | grep -i "$filter") || true
  if [ -z "$instances" ]; then
    echo -e "${RED}No running instances matching '$filter'${NC}"
    return 1
  fi

  local -a ids names
  local i=1 id name state
  while IFS=$'\t' read -r id name state; do
    ids[i]=$id
    names[i]=$name
    echo "$i) $name ($id) - $state"
    ((i++))
  done <<< "$instances"

  echo -en "\n${YELLOW}Instance number: ${NC}"
  local n
  read -r n
  if [[ ! "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -ge "$i" ]; then
    echo -e "${RED}Invalid selection${NC}"
    return 1
  fi

  local sid=${ids[$n]} sname=${names[$n]}
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
