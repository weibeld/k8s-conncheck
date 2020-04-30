#!/bin/sh

is_reachable() {
  if ping -q -c 1 -t 4 "$1" >/dev/null; then
    echo true
  else
    echo false
  fi
}

write() {
  test=$1
  ip=$2
  success=$3
  [[ "$success" = true ]] && icon="\xE2\x9C\x85" || icon="\xE2\x9D\x8C"
  printf "$icon $test (=> $ip)\n"
}

# Self
test="Self"
ip=$PROBER_IP
success=$(is_reachable "$ip")
write "$test" "$ip" "$success"

# Pod on same node
test="Pod on same node"
ip=$(echo "$PODS" | jq -r "map(select(.node==\"$PROBER_NODE\"))[0].ip")
success=$(is_reachable "$ip")
write "$test" "$ip" "$success"

# Pod on different node
test="Pod on different node"
ip=$(echo "$PODS" | jq -r "map(select(.node!=\"$PROBER_NODE\"))[0].ip")
success=$(is_reachable "$ip")
write "$test" "$ip" "$success"

# Same node
test="Same node"
ip=$(echo "$NODES" | jq -r "map(select(.name==\"$PROBER_NODE\"))[0] | .ip")
success=$(is_reachable "$ip")
write "$test" "$ip" "$success"

# Different node
test="Different node"
ip=$(echo "$NODES" | jq -r "map(select(.name!=\"$PROBER_NODE\"))[0] | .ip")
success=$(is_reachable "$ip")
write "$test" "$ip" "$success"
