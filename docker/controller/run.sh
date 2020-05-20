#!/bin/sh

set -e

# Read URL of the API server from the kubelet's kubeconfig file
api_server_url=$(yq read /etc/kubernetes/kubelet.conf 'clusters[0].cluster.server')

# kubectl wrapper function with connection flags. By default, kubectl connects
# to to the API server through the IP address in $KUBERNETES_SERVICE_HOST and
# uses the below well-known locations for the authentication token and CA cert.
# However, $KUBERNETES_SERVICE_HOST contains the IP address of the "kubernetes"
# Service, and conncheck should not assume that Service networking is working.
# For that reason, conncheck specifies the proper IP address of the API server
# in the --server flag, and if this flag is set, the authentication token and
# CA cert also have to be specified explicitly with the corresponding flags.
kubectlw() {
  kubectl \
    --server "$api_server_url" \
    --certificate-authority /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    --token "$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    "$@"
}

# Helper function for printing a log line consisting of a timestamp and message
log() {
  color_ts="\e[94;1m"
  color_msg="\e[;1m"
  echo -e "$color_ts$(date -Isec) $color_msg$1\e[0m"
}

# Invoked after the start of a prober Pod before the first test result is read.
# Receives the following args:
#   $1: name of the prober Pod
#   $2: IP address of the prober Pod
#   $3: name of the node on which the prober Pod is running
#   $4: IP address of the node on which the prober Pod is running
init() {
  :
}

# Invoked for each test result of a prober Pod (a test consists of pinging
# a target; a target may be a Pod or a node; a prober Pod performs a sequence
# of tests with different targets). Receives the following args:
#   $1: test result
# The test result is a JSON object (formatted as a single line) with the
# following fields:
#   - test_id (string):     identifier of the type of test being performed
#   - target_ip (string):   IP address of the target 
#   - target_name (string): friendly name of the target
#   - success (boolean):    whether the target could be reached or not
process_test_result() {
  test_id=$(echo "$1" | jq -r '.test_id')
  target_ip=$(echo "$1" | jq -r '.target_ip')
  target_name=$(echo "$1" | jq -r '.target_name')
  success=$(echo "$1" | jq -r '.success')

  case "$test_id" in
    pod-self) msg="To self" ;;
    pod-pod-local) msg="To pod on same node" ;;
    pod-pod-remote) msg="To pod on different node" ;;
    pod-node-local) msg="To own node" ;;
    pod-node-remote) msg="To different node" ;;
    pod-service) msg="To service" ;;
    dns-internal) msg="DNS resolution of internal name" ;;
    dns-external) msg="DNS resolution of external name" ;;
    internet) msg="To internet"
  esac

  case "$success" in
    true)
      icon="\xE2\x9C\x85" 
      color="\e[92;1m"
      ;;
    false)
      icon="\xe2\x9b\x94"
      color="\e[91;1m"
      ;;
  esac

  [[ -n "$target_ip" ]] && sep=" " || sep=""
  echo -e "$color  $icon $msg (\"$target_name\"$sep$target_ip)\e[0m"
}

# Invoked after all tests of a prober Pod have been completed before the prober
# Pod is deleted. Receives no arguments.
finalize() {
  :
}

#==============================================================================#
# Begin of execution
#==============================================================================#

log "Initialising..."

# Wait until all target Pods are running
while ! daemonset=$(kubectlw get daemonset conncheck-target -o json) ||
  [[ "$(echo "$daemonset" | jq '.status.numberReady')" -ne "$(echo "$daemonset" | jq '.status.desiredNumberScheduled')" ]]; do
  sleep 1
done

# Query cluster topology
pod_topology=$(kubectlw get pods -l "app=conncheck-target" -o json | jq -c '[.items[] | {name: .metadata.name, ip: .status.podIP, node: .spec.nodeName}]')
node_topology=$(kubectlw get nodes -o json | jq -c '[.items[] | {name: .metadata.name, ip: .status.addresses[] | select(.type == "InternalIP") | .address}]')
service_topology=$(kubectlw get service conncheck-service -o json | jq -c '{name: .metadata.name, ip: .spec.clusterIP, port: .spec.ports[0].port}')

pod_manifest=$(mktemp)
cat <<EOF >$pod_manifest
apiVersion: v1
kind: Pod
metadata:
spec:
  restartPolicy: OnFailure
  containers:
  - image: weibeld/k8s-conncheck-prober
    name: k8s-conncheck-prober
    imagePullPolicy: Always
    env:
      - name: PODS
        value: '$pod_topology'
      - name: NODES
        value: '$node_topology'
      - name: SERVICE
        value: '$service_topology'
      - name: SELF_POD_IP
        valueFrom:
          fieldRef:
           fieldPath: status.podIP
      - name: SELF_POD_NAME
        valueFrom:
          fieldRef:
            fieldPath: metadata.name
      - name: SELF_NODE_NAME
        valueFrom:
          fieldRef:
           fieldPath: spec.nodeName
EOF

# Run two prober Pods: one in the Pod network and one in the host network
for run in pod_network host_network; do

  case "$run" in
    pod_network)
      pod_name=conncheck-prober
      yq write -i "$pod_manifest" metadata.name "$pod_name"
      ;;
    host_network)
      pod_name=conncheck-prober-host-network
      yq write -i "$pod_manifest" metadata.name "$pod_name"
      yq write -i "$pod_manifest" spec.hostNetwork true
      yq write -i "$pod_manifest" spec.dnsPolicy ClusterFirstWithHostNet
      ;;
  esac

  # Create prober Pod
  log "Creating Pod \"$pod_name\"..."
  kubectlw create -f "$pod_manifest" >/dev/null

  # Wait until prober Pod has started
  while [[ "$(kubectlw get pod "$pod_name" -o jsonpath='{.status.phase}')" == Pending ]]; do sleep 1; done

  # Query details of prober Pod
  tmp=$(kubectlw get pod "$pod_name" -o json | jq -r '[.status.podIP,.spec.nodeName,.status.hostIP] | join(",")')
  pod_ip=$(echo "$tmp" | cut -d , -f 1)
  node_name=$(echo "$tmp" | cut -d , -f 2)
  node_ip=$(echo "$tmp" | cut -d , -f 3)
  log "Running tests on Pod \"$pod_name\" $pod_ip (running on node \"$node_name\" $node_ip)"

  # Invoke 'init' callback
  init "$pod_name" "$pod_ip" "$node_name" "$node_ip"

  # Read test results from prober Pod and invoke 'process_test_result' callbacks
  kubectlw logs -f "$pod_name" | while read -r line; do 
    [[ "$line" = EOF ]] && break
    process_test_result "$line"
  done

  # Invoke 'finalize' callback
  finalize

  # Delete prober Pod
  log "Deleting Pod \"$pod_name\""
  kubectlw delete pod "$pod_name" --wait=false >/dev/null

done
