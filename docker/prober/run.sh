#!/bin/sh

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

write_result() {
  test_id=$1
  target_ip=$2
  target_name=$3
  success=$4
  printf '{"test_id":"%s","target_ip":"%s","target_name":"%s","success":%s}\n' "$test_id" "$target_ip" "$target_name" "$success"
}

# Self
test_id=pod-self
target_ip=$SELF_POD_IP
target_name=$SELF_POD_NAME
icmp "$target_ip" && success=true || success=false
write_result "$test_id" "$target_ip" "$target_name" "$success"

# Pod on same node
test_id=pod-pod-local
tmp=$(echo "$PODS" | jq -r "map(select(.node==\"$SELF_NODE_NAME\"))[0] | .ip + \",\" + .name")
target_ip=$(echo "$tmp" | cut -d , -f 1)
target_name=$(echo "$tmp" | cut -d , -f 2)
icmp "$target_ip" && success=true || success=false
write_result "$test_id" "$target_ip" "$target_name" "$success"

# Pod on different node
test_id=pod-pod-remote
tmp=$(echo "$PODS" | jq -r "map(select(.node!=\"$SELF_NODE_NAME\"))[0] | .ip + \",\" + .name")
target_ip=$(echo "$tmp" | cut -d , -f 1)
target_name=$(echo "$tmp" | cut -d , -f 2)
icmp "$target_ip" && success=true || success=false
write_result "$test_id" "$target_ip" "$target_name" "$success"

# Same node
test_id=pod-node-local
tmp=$(echo "$NODES" | jq -r "map(select(.name==\"$SELF_NODE_NAME\"))[0] | .ip + \",\" + .name")
target_ip=$(echo "$tmp" | cut -d , -f 1)
target_name=$(echo "$tmp" | cut -d , -f 2)
icmp "$target_ip" && success=true || success=false
write_result "$test_id" "$target_ip" "$target_name" "$success"

# Different node
test_id=pod-node-remote
tmp=$(echo "$NODES" | jq -r "map(select(.name!=\"$SELF_NODE_NAME\"))[0] | .ip + \",\" + .name")
target_ip=$(echo "$tmp" | cut -d , -f 1)
target_name=$(echo "$tmp" | cut -d , -f 2)
icmp "$target_ip" && success=true || success=false
write_result "$test_id" "$target_ip" "$target_name" "$success"

# Service
test_id=pod-service
target_ip=$(echo "$SERVICE" | jq -r .ip)
target_port=$(echo "$SERVICE" | jq -r .port)
target_name=$(echo "$SERVICE" | jq -r .name)
tcp "$target_ip" "$target_port" && success=true || success=false
write_result "$test_id" "$target_ip" "$target_name" "$success"

# Internal DNS
test_id=dns-internal
target_name=$(echo "$SERVICE" | jq -r .name)
dns "$target_name" && success=true || success=false
write_result "$test_id" "" "$target_name" "$success"

# External DNS
test_id=dns-external
target_name=kubernetes.io
dns "$target_name" && success=true || success=false
write_result "$test_id" "" "$target_name" "$success"

# Internet
test_id=internet
target_name=a.root-servers.net
target_ip=198.41.0.4
icmp "$target_ip" && success=true || success=false
write_result "$test_id" "$target_ip" "$target_name" "$success"

echo EOF
