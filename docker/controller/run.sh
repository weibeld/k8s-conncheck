#!/bin/sh

#set -e

log() {
  echo -e "\e[94;1m$(date +'%Y/%m/%d-%H:%M:%S-%Z')\e[0m $@"
}

# Read URL of the API server from the kubelet's kubeconfig file
#api_server_url=$(yq read /etc/kubernetes/kubelet.conf 'clusters[0].cluster.server')

# Extract IP address (and port) of the API server from the iptables rules for
# the "default/kubernetes" Service. Accessing iptables requires the container
# to run in privileged mode. This works only if kube-proxy uses the 'iptables'
# proxy mode (i.e. not with the IPVS proxy mode), but this is NOT YET TESTED.
service=$(iptables -t nat -L KUBE-SERVICES | grep default/kubernetes | grep '^KUBE-SVC' | awk '{print $1}')
endpoint=$(iptables -t nat -L "$service" | grep '^KUBE-SEP' | head -n 1| awk '{print $1}')
apiserver_ip=$(iptables -t nat -S "$endpoint" | grep DNAT | awk '{for (i=1;i<=NF;i++) if ($i=="--to-destination") print $(i+1)}')
apiserver_url=https://"$apiserver_ip"

# Wrapper around kubectl for connecting directly to the API server. By default,
# kubectl finds out how to connect to the API server with the information in the
# $KUBERNETES_SERVICE_HOST and $KUBERNETES_SERVICE_PORT environment variables.
# However, this info corresponds to the "kubernetes" Service in the "default"
# namespace which exposes the API server. Thus, using this behaviour presumes
# that Service networking is already working in the cluster, but this is just 
# what the connectivity checker is supposed to check. For this reason, kubectl
# must connect directly to the IP address of the API server extracted above,
# which is specified in the --server  flag below. If the --server flag is set,
# the --certificate-authority and  --token flags must also be explicitly set.
kubectlw() {
  kubectl \
    --server "$apiserver_url" \
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

sleep infinity
 
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
