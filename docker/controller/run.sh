#!/bin/sh

log() {
  echo -e "\e[94;1m$(date +'%Y/%m/%d-%H:%M:%S-%Z')\e[;1m $@\e[0m"
}

error() {
  log "\e[91;1mError: $@\e[0m"
  exit 1
}

# Wrapper around kubectl for connecting directly to the API server. By default,
# kubectl finds out how to connect to the API server with the information in the
# $KUBERNETES_SERVICE_HOST and $KUBERNETES_SERVICE_PORT environment variables.
# However, this info corresponds to the "kubernetes" Service in the "default"
# namespace which exposes the API server. Thus, using this behaviour presumes
# that Service networking is already working in the cluster, but this is what
# the connectivity checker is supposed to check. For this reason, kubectl must
# connect directly to the URL of the API server (determined below). This URL
# is then used for the --server  flag of kubectl. If the --server flag is set,
# the --certificate-authority and  --token flags must also be explicitly set.
kubectlw() {
  kubectl \
    --server "$apiserver_url" \
    --certificate-authority /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    --token "$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    "$@"
}

# Extract API server URL. The IP address and port are extracted from the
# iptables rules for the "default/kubernetes" Service which maps a ClusterIP
# (IP address and port) to the IP address and port of the API server. Accessing
# iptables requires the container to run in privileged mode. This extraction
# works only if kube-proxy uses the 'iptables' since the 'ipvs' proxy mode does
# not create iptables rules (NOT YET TESTED).
service=$(iptables -t nat -L KUBE-SERVICES | grep default/kubernetes | grep '^KUBE-SVC' | awk '{print $1}')
endpoint=$(iptables -t nat -L "$service" | grep '^KUBE-SEP' | head -n 1| awk '{print $1}')
apiserver_ip=$(iptables -t nat -S "$endpoint" | grep DNAT | awk '{for (i=1;i<=NF;i++) if ($i=="--to-destination") print $(i+1)}')
apiserver_url=https://"$apiserver_ip"
log "Detected API server URL: $apiserver_url"

# Check API server URL
log "Checking API server URL..."
if ! kubectlw --request-timeout=3s version 1>/dev/null 2>&1; then
  error "API server URL $apiserver_url is invalid"
fi
log "API server URL is valid"

# Wait until all target Pods are ready
log "Waiting for target Pods to become ready..."
while ! daemonset=$(kubectlw get daemonset conncheck-target -o json) ||
  [[ "$(echo "$daemonset" | jq '.status.numberReady')" -ne "$(echo "$daemonset" | jq '.status.desiredNumberScheduled')" ]]; do
  sleep 1
done

# Gather cluster topology information into JSON objects
log "Gathering cluster topology information..."
# Pods: [{"name":"","ip":"","node":""},{}]
pod_topology=$(kubectlw get pods -l "app=conncheck-target" -o json | jq -c '[.items[] | {name: .metadata.name, ip: .status.podIP, node: .spec.nodeName}]')
# Nodes: [{"name":"","ip":""},{}]
node_topology=$(kubectlw get nodes -o json | jq -c '[.items[] | {name: .metadata.name, ip: .status.addresses[] | select(.type == "InternalIP") | .address}]')
# Service: {"name":"","ip":"","port":""}
service_topology=$(kubectlw get service conncheck-service -o json | jq -c '{name: .metadata.name, ip: .spec.clusterIP, port: .spec.ports[0].port}')

# Escape JSON objects so that they can be used as JSON string values
json_escape() { sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g'; }
pod_topology_escaped=$(echo "$pod_topology" | json_escape)
node_topology_escaped=$(echo "$node_topology" | json_escape)
service_topology_escaped=$(echo "$service_topology" | json_escape)

# Manifest for the prober ReplicaSet (null values will be set dynamically)
manifest=$(cat <<EOF
{
  "apiVersion": "apps/v1",
  "kind": "ReplicaSet",
  "metadata": {
    "name": null
  },
  "spec": {
    "replicas": 1,
    "selector": {
      "matchLabels": {
        "app": null
      }
    },
    "template": {
      "metadata": {
        "labels": {
          "app": null
        }
      },
      "spec": {
        "containers": [
          {
            "image": "weibeld/k8s-conncheck-prober",
            "name": "k8s-conncheck-prober",
            "imagePullPolicy": "Always",
            "env": [
              {
                "name": "PODS",
                "value": "$pod_topology_escaped"
              },
              {
                "name": "NODES",
                "value": "$node_topology_escaped"
              },
              {
                "name": "SERVICE",
                "value": "$service_topology_escaped"
              },
              {
                "name": "SELF_POD_NAME",
                "valueFrom": {
                  "fieldRef": {
                    "fieldPath": "metadata.name"
                  }
                }
              },
              {
                "name": "SELF_POD_IP",
                "valueFrom": {
                  "fieldRef": {
                    "fieldPath": "status.podIP"
                  }
                }
              },
              {
                "name": "SELF_NODE_NAME",
                "valueFrom": {
                  "fieldRef": {
                    "fieldPath": "spec.nodeName"
                  }
                }
              },
              {
                "name": "SELF_NODE_IP",
                "valueFrom": {
                  "fieldRef": {
                    "fieldPath": "status.hostIP"
                  }
                }
              }
            ]
          }
        ]
      }
    }
  }
}
EOF
)

for name in conncheck-prober conncheck-prober-hostnet; do
  # Adapt manifest for the specific ReplicaSet
  m=$manifest
  m=$(
    echo "$m" |
    jq ".metadata.name = \"$name\"" |
    jq ".spec.selector.matchLabels.app = \"$name\"" |
    jq ".spec.template.metadata.labels.app = \"$name\""
  )
  if [[ "$name" = conncheck-prober-hostnet ]]; then
    m=$(
      echo "$m" |
      jq '.spec.template.spec.hostNetwork = true' |
      jq '.spec.template.spec.dnsPolicy = "ClusterFirstWithHostNet"'
    )
  fi
  file=$(mktemp) && echo "$m" >"$file"
  
  # If the ReplicaSet already exists, update it and then restart the Pod. This
  # occurs if the controller Pod has already been running and is restarted.
  if kubectlw get replicaset "$name" 1>/dev/null 2>&1; then
    log "Updating ReplicaSet \"$name\" and restarting Pod..."
    kubectlw apply -f "$file" >/dev/null
    kubectl delete pods -l app="$name" >/dev/null

  # If the ReplicaSet doesn't exist, create it. This occurs if the controller Pod
  # runs for the first time.
  else
    log "Creating ReplicaSet \"$name\"..."
    kubectlw apply -f "$file" >/dev/null
  fi
done

log Done
sleep infinity
