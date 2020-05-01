#!/bin/sh

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

# Read and process a test result from the prober Pod. Each test consists of
# testing the connectivity to the IP address of a target. A target may be a Pod
# or node. A test result consists of a JSON object (formatted on a single line)
# with the following keys:
#   - test_id:     identifier of the type of test being performed
#   - target_ip:   IP address of the target 
#   - target_name: friendly name of the target
#   - success:     boolean; true if the target could be reached, false if not
process() {
  test_result=$1
  echo "$test_result"
}

# Read the logs of the prober Pod
kubectl logs -f conncheck-prober | while read -r line; do 
  [[ "$line" = EOF ]] && break
  process "$line"
done

kubectl delete pod conncheck-prober --wait=false >/dev/null
