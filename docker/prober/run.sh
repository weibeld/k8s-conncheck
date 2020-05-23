#!/bin/sh

#------------------------------------------------------------------------------#
# Output functions
#------------------------------------------------------------------------------#

log() {
  echo -e "\e[94;1m$(date +'%Y/%m/%d-%H:%M:%S-%Z')\e[;1m $@\e[0m"
}

format_result() {
  description=$1
  target_ip=$2
  target_name=$3
  success=$4

  case "$success" in
    true)
      success_color="\e[92;1m"
      success_msg=SUCCESS
      ;;
    false)
      success_color="\e[91;1m"
      success_msg=FAILURE
      ;;
  esac

  [[ -n "$target_ip" ]] && sep=" " || sep=""

  echo -e "$success_color$success_msg\e[;1m $description (\"$target_name\"$sep$target_ip)"
}

#------------------------------------------------------------------------------#
# Connectivity check functions
#------------------------------------------------------------------------------#

icmp() {
  ip=$1
  # If using the -t option, the requests fail when pining a host in the internet
  ping -c 1 "$ip" 1>/dev/null 2>&1
}

tcp() {
  ip=$1
  port=$2
  nc -z -w 3 "$ip" "$port" 1>/dev/null 2>&1
}

dns() {
  name=$1
  nslookup "$name" 1>/dev/null 2>&1
}

#------------------------------------------------------------------------------#
# Begin of execution
#------------------------------------------------------------------------------#

log "Pod \"$SELF_POD_NAME\" $SELF_POD_IP (node \"$SELF_NODE_NAME\" $SELF_NODE_IP)"

description="Self"
target_ip=$SELF_POD_IP
target_name=$SELF_POD_NAME
if icmp "$target_ip"; then
  success=true
else
  success=false
fi
log "$(format_result "$description" "$target_ip" "$target_name" "$success")"

description="Pod on local node"
target=$(echo "$POD_INFO" | jq "map(select(.node==\"$SELF_NODE_NAME\")) | first")
target_ip=$(echo "$target" | jq -r .ip)
target_name=$(echo "$target" | jq -r .name)
if icmp "$target_ip"; then
  success=true
else
  success=false
fi
log "$(format_result "$description" "$target_ip" "$target_name" "$success")"

description="Pod on remote node"
target=$(echo "$POD_INFO" | jq "map(select(.node!=\"$SELF_NODE_NAME\")) | first")
target_ip=$(echo "$target" | jq -r .ip)
target_name=$(echo "$target" | jq -r .name)
if icmp "$target_ip"; then
  success=true
else
  success=false
fi
log "$(format_result "$description" "$target_ip" "$target_name" "$success")"

description="Local node"
target=$(echo "$NODE_INFO" | jq "map(select(.name==\"$SELF_NODE_NAME\")) | first")
target_ip=$(echo "$target" | jq -r .ip)
target_name=$(echo "$target" | jq -r .name)
if icmp "$target_ip"; then
  success=true
else
  success=false
fi
log "$(format_result "$description" "$target_ip" "$target_name" "$success")"

description="Remote node"
target=$(echo "$NODE_INFO" | jq "map(select(.name!=\"$SELF_NODE_NAME\")) | first")
target_ip=$(echo "$target" | jq -r .ip)
target_name=$(echo "$target" | jq -r .name)
if icmp "$target_ip"; then
  success=true
else
  success=false
fi
log "$(format_result "$description" "$target_ip" "$target_name" "$success")"

description="Service"
target_ip=$(echo "$SERVICE_INFO" | jq -r .ip)
target_name=$(echo "$SERVICE_INFO" | jq -r .name)
target_port=$(echo "$SERVICE_INFO" | jq -r .port)
if tcp "$target_ip" "$target_port"; then
  success=true
else
  success=false
fi
log "$(format_result "$description" "$target_ip" "$target_name" "$success")"

description="Internet"
target_ip=198.41.0.4
target_name=a.root-servers.net
if icmp "$target_ip"; then
  success=true
else
  success=false
fi
log "$(format_result "$description" "$target_ip" "$target_name" "$success")"

description="Internal DNS resolution"
target_ip=""
target_name=$(echo "$SERVICE_INFO" | jq -r .name)
if dns "$target_name"; then
  success=true
else
  success=false
fi
log "$(format_result "$description" "$target_ip" "$target_name" "$success")"

description="External DNS resolution"
target_ip=""
target_name=kubernetes.io
if dns "$target_name"; then
  success=true
else
  success=false
fi
log "$(format_result "$description" "$target_ip" "$target_name" "$success")"

sleep infinity
