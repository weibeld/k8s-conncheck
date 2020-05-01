#!/bin/sh

# Invoked before the tests of a prober Pod start. Receives the following args:
#   $1: IP address of the prober Pod
#   $2: name of the node on which the prober Pod is running
#   $3: IP address of the node on which the prober Pod is running
init() {
  cat <<EOF
$(date -Isec) Tests from temporary Pod 'conncheck-prober' ($1) on node '$2' ($3)
EOF
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
  test_result=$1
  echo "$test_result"
}

# Invoked after all tests of the prober Pod has been completed and immediately
# before the prober Pod is deleted.
wrap_up() {
  echo
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
  name: conncheck-prober
spec:
  restartPolicy: OnFailure
  containers:
  - image: weibeld/k8s-conncheck-prober
    name: conncheck-prober
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
kubectl create -f "$PROBER_MANIFEST" >/dev/null
while [[ $(kubectl get pod conncheck-prober -o jsonpath='{.status.phase}') != Running ]]; do sleep 1; done

# Initialise the tests
tmp=$(kubectl get pod conncheck-prober -o json | jq -r '[.status.podIP,.spec.nodeName,.status.hostIP] | join(",")')
pod_ip=$(echo "$tmp" | cut -d , -f 1)
node_name=$(echo "$tmp" | cut -d , -f 2)
node_ip=$(echo "$tmp" | cut -d , -f 3)
init "$pod_ip" "$node_name" "$node_ip"

# Process test results
kubectl logs -f conncheck-prober | while read -r line; do 
  [[ "$line" = EOF ]] && break
  process_test_result "$line"
done

# Finish the tests
wrap_up
kubectl delete pod conncheck-prober --wait=false >/dev/null
