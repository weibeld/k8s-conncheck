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
# Job
#apiVersion: batch/v1
#kind: Job
#metadata:
#  name: conncheck-prober
#spec:
#  template:
#    # Alpha feature: requires TTLAfterFinished feature gate
#    ttlSecondsAfterFinished: 0
#    spec:
#      # Must be Never or OnFailure
#      restartPolicy: OnFailure 
#      containers:
#      - image: weibeld/k8s-conncheck-prober
#        name: conncheck-prober
#        imagePullPolicy: Always
#        #command: ["sleep", "infinity"]
#        env:
#          - name: PODS
#            value: '$PODS'
#          - name: NODES
#            value: '$NODES'
#          - name: SELF_IP
#            valueFrom:
#              fieldRef:
#                fieldPath: status.podIP
#          - name: SELF_POD
#            valueFrom:
#              fieldRef:
#                fieldPath: metadata.name
#          - name: SELF_NODE
#            valueFrom:
#              fieldRef:
#                fieldPath: spec.nodeName
EOF

kubectl create -f "$PROBER_MANIFEST"
