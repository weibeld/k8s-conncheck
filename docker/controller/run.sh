#!/bin/sh

# Invoked before the tests of a prober Pod start. Receives the following args:
#   $1: name of the prober Pod
#   $2: IP address of the prober Pod
#   $3: name of the node on which the prober Pod is running
#   $4: IP address of the node on which the prober Pod is running
init() {
  #color1="\e[34;1m" # Blue
  color1="\e[94;1m"
  color2="\e[97;1m"  # White
  echo -e "$color1$(date -Isec) ${color2}Connectivity check on Pod $1 $2 (running on node $3 $4)\e[0m"
}

# Invoked for each test result that the prober Pod returns (a single test 
# consists of pinging a target and testing connectivity; a target may be a Pod
# or a node; a prober Pod performs a sequence of such tests). Receives the
# following argument:
#   $1: test result
# The test result is a JSON object (formatted as a single line) with the
# following fields:
#   - test_id (string):     identifier of the test being performed
#   - target_ip (string):   IP address of the target 
#   - target_name (string): friendly name of the target
#   - success (boolean):    whether the target could be reached or not
process_test_result() {
  test_id=$(echo "$1" | jq -r '.test_id')
  target_ip=$(echo "$1" | jq -r '.target_ip')
  target_name=$(echo "$1" | jq -r '.target_name')
  success=$(echo "$1" | jq -r '.success')

  case "$test_id" in
    pod-self) msg="To itself" ;;
    pod-pod-local) msg="To pod on same node" ;;
    pod-pod-remote) msg="To pod on different node" ;;
    pod-node-local) msg="To own node" ;;
    pod-node-remote) msg="To different node" ;;
  esac

  case "$success" in
    true)
      icon="\xE2\x9C\x85" 
      color="\e[92;1m"
      ;;
    false)
      #icon="\xE2\x9D\x8C"
      icon="\xe2\x9b\x94"
      color="\e[91;1m"
      ;;
  esac

  echo -e "$color  $icon $msg ($target_name $target_ip)\e[0m"
}

# Invoked after all tests of the prober Pod has been completed and immediately
# before the prober Pod is deleted.
wrap_up() {
  :
}

API_SERVER=$(yq read /etc/kubernetes/kubelet.conf 'clusters[0].cluster.server')

PODS=$(\
  kubectl \
    --server "$API_SERVER" \
    --certificate-authority /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    --token $(cat /var/run/secrets/kubernetes.io/serviceaccount/token) \
    --selector app=conncheck-target \
    --output json \
    get pods |
    jq -c '[.items[] | {name: .metadata.name, ip: .status.podIP, node: .spec.nodeName}]' \
)

# TODO: restrict nodes to worker nodes
NODES=$(\
  kubectl \
    --server "$API_SERVER" \
    --certificate-authority /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    --token $(cat /var/run/secrets/kubernetes.io/serviceaccount/token) \
    --output json \
    get nodes |
    jq -c '[.items[] | {name: .metadata.name, ip: .status.addresses[] | select(.type == "InternalIP") | .address}]' \
)

PROBER_MANIFEST=$(mktemp)
cat <<EOF >$PROBER_MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: placeholder
spec:
  restartPolicy: OnFailure
  containers:
  - image: weibeld/k8s-conncheck-prober
    name: k8s-conncheck-prober
    imagePullPolicy: Always
    #command: ["sleep", "infinity"]
    env:
      - name: PODS
        value: '$PODS'
      - name: NODES
        value: '$NODES'
      - name: SELF_IP
        valueFrom:
          fieldRef:
           fieldPath: status.podIP
      - name: SELF_POD
        valueFrom:
          fieldRef:
            fieldPath: metadata.name
      - name: SELF_NODE
        valueFrom:
          fieldRef:
           fieldPath: spec.nodeName
EOF

for run in pod_network host_network; do

  # Adapt manifest
  case "$run" in
    pod_network)
      pod_name=conncheck-prober
      is_host_network=false
      ;;
    host_network)
      pod_name=conncheck-prober-host
      is_host_network=true
      ;;
  esac
  yq write -i "$PROBER_MANIFEST" metadata.name "$pod_name"
  yq write -i "$PROBER_MANIFEST" spec.hostNetwork "$is_host_network"

  kubectl create -f "$PROBER_MANIFEST" >/dev/null
  while [[ $(kubectl get pod "$pod_name" -o jsonpath='{.status.phase}') != Running ]]; do sleep 1; done

  # Initialise the tests
  tmp=$(kubectl get pod "$pod_name" -o json | jq -r '[.status.podIP,.spec.nodeName,.status.hostIP] | join(",")')
  pod_ip=$(echo "$tmp" | cut -d , -f 1)
  node_name=$(echo "$tmp" | cut -d , -f 2)
  node_ip=$(echo "$tmp" | cut -d , -f 3)
  init "$pod_name" "$pod_ip" "$node_name" "$node_ip"

  # Process test results
  kubectl logs -f "$pod_name" | while read -r line; do 
    [[ "$line" = EOF ]] && break
    process_test_result "$line"
  done

  # Finish the tests
  wrap_up
  kubectl delete pod "$pod_name" --wait=false >/dev/null

done

