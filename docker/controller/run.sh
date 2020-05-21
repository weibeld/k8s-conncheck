#!/bin/sh

#set -e

log() {
  echo -e "\e[94;1m$(date -Isec)\e[0m $@"
}

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

template=$(mktemp)
cat <<EOF >$template
apiVersion: apps/v1
kind: Deployment
metadata:
spec:
  replicas: 1
  selector:
    matchLabels:
  template:
    metadata:
      labels:
    spec:
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
          - name: SELF_POD_NAME
            valueFrom:
              fieldRef:
                fieldPath: metadata.name
          - name: SELF_POD_IP
            valueFrom:
              fieldRef:
               fieldPath: status.podIP
          - name: SELF_NODE_NAME
            valueFrom:
              fieldRef:
               fieldPath: spec.nodeName
          - name: SELF_NODE_IP
            valueFrom:
              fieldRef:
               fieldPath: status.hostIP
EOF

# Run two prober Deployments: one in the Pod network and one in the host network
for name in conncheck-prober conncheck-prober-hostnet; do

  yq write -i "$template" metadata.name "$name"
  yq write -i "$template" spec.selector.matchLabels.app "$name"
  yq write -i "$template" spec.template.metadata.labels.app "$name"

  if [[ "$name" = conncheck-prober-hostnet ]]; then
    yq write -i "$template" spec.template.spec.hostNetwork true
    yq write -i "$template" spec.template.spec.dnsPolicy ClusterFirstWithHostNet    
  fi

  log "Creating Deployment \"$name\"..."
  kubectlw create -f "$template" >/dev/null

done
 
#  # Patch Pod template of Deployment with topology information (restarts Pod)
#  log "Patching \"$deployment_name\"..."
#  patch=$(cat <<EOF
#spec:
#  template:
#    spec:
#      containers:
#        - name: k8s-conncheck-prober
#          env:
#            - name: PODS
#              value: '$pod_topology'
#            - name: NODES
#              value: '$node_topology'
#            - name: SERVICE 
#              value: '$service_topology'
#EOF
#)
#  kubectlw patch deployment "$deployment_name" -p "$patch" >/dev/null
