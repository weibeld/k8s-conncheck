#!/bin/sh

is_reachable() {
  ping -q -c 1 -t 4 "$1" >/dev/null \
    && echo true \
    || echo false
}

write() {
  test_id=$1
  target_ip=$2
  target_name=$3
  success=$4
  printf '{"test_id":"%s","target_ip":"%s","target_name":"%s","success":%s}\n' \
    "$test_id" "$target_ip" "$target_name" "$success"
}

# Self
test_id=pod-self
target_ip=$SELF_IP
target_name=$SELF_POD
success=$(is_reachable "$target_ip")
write "$test_id" "$target_ip" "$target_name" "$success"

# Pod on same node
test_id=pod-pod-local
tmp=$(echo "$PODS" | jq -r "map(select(.node==\"$SELF_NODE\"))[0] | .ip + \",\" + .name")
target_ip=$(echo "$tmp" | cut -d , -f 1)
target_name=$(echo "$tmp" | cut -d , -f 2)
success=$(is_reachable "$target_ip")
write "$test_id" "$target_ip" "$target_name" "$success"

# Pod on different node
test_id=pod-pod-remote
tmp=$(echo "$PODS" | jq -r "map(select(.node!=\"$SELF_NODE\"))[0] | .ip + \",\" + .name")
target_ip=$(echo "$tmp" | cut -d , -f 1)
target_name=$(echo "$tmp" | cut -d , -f 2)
success=$(is_reachable "$target_ip")
write "$test_id" "$target_ip" "$target_name" "$success"

# Same node
test_id=pod-node-local
tmp=$(echo "$NODES" | jq -r "map(select(.name==\"$SELF_NODE\"))[0] | .ip + \",\" + .name")
target_ip=$(echo "$tmp" | cut -d , -f 1)
target_name=$(echo "$tmp" | cut -d , -f 2)
success=$(is_reachable "$target_ip")
write "$test_id" "$target_ip" "$target_name" "$success"

# Different node
test_id=pod-node-local
tmp=$(echo "$NODES" | jq -r "map(select(.name!=\"$SELF_NODE\"))[0] | .ip + \",\" + .name")
target_ip=$(echo "$tmp" | cut -d , -f 1)
target_name=$(echo "$tmp" | cut -d , -f 2)
success=$(is_reachable "$target_ip")
write "$test_id" "$target_ip" "$target_name" "$success"
