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
  # In some clusters, the API server certificate doen't include the IP address
  # of the API server as a subject alternative name (for example, on AKS). In
  # these cases, verfification of the API server certificate must be disabled.
  if [[ -n "$skip_server_cert_verification" ]]; then
    server_cert_flag=--insecure-skip-tls-verify=true
  else
    server_cert_flag=--certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  fi
  kubectl \
    --server "$apiserver_url" \
    --token "$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    "$server_cert_flag" \
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
curl --connect-timeout 3 --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt --header "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" "$apiserver_url" >/dev/null 2>&1
# Exit code 60 means that the connection succeeded, but curl could not verify
# the server cert with the provided CA cert. In this case, enable skipping the
# verificatino of the API server certificate for all future kubectl commands.
case "$?" in
  0)  unset skip_server_cert_verification ;;
  60) skip_server_cert_verification=true ;;
  *)  error "API server URL $apiserver_url is invalid" ;;
esac
log "API server URL is valid"

# Wait until all target Pods are ready
log "Waiting for target Pods to become ready..."
while ! daemonset=$(kubectlw get daemonset target -o json) ||
  [[ "$(echo "$daemonset" | jq '.status.numberReady')" -ne "$(echo "$daemonset" | jq '.status.desiredNumberScheduled')" ]]; do
  sleep 1
done

# Gather cluster topology information into JSON objects
log "Gathering cluster topology information..."
# Pods: [{"name":"","ip":"","node":""},{}]
pod_info=$(kubectlw get pods -l app=target -o json | jq -c '[.items[] | {name: .metadata.name, ip: .status.podIP, node: .spec.nodeName}]')
# Nodes: [{"name":"","ip":""},{}]
node_info=$(kubectlw get nodes -o json | jq -c '[.items[] | {name: .metadata.name, ip: .status.addresses[] | select(.type == "InternalIP") | .address}]')
# Service: {"name":"","ip":"","port":""}
service_info=$(kubectlw get service target-service -o json | jq -c '{name: .metadata.name, ip: .spec.clusterIP, port: .spec.ports[0].port}')

# Escape JSON objects so that they can be used as JSON string values
json_escape() { sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g'; }
pod_info_escaped=$(echo "$pod_info" | json_escape)
node_info_escaped=$(echo "$node_info" | json_escape)
service_info_escaped=$(echo "$service_info" | json_escape)

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
                "name": "POD_INFO",
                "value": "$pod_info_escaped"
              },
              {
                "name": "NODE_INFO",
                "value": "$node_info_escaped"
              },
              {
                "name": "SERVICE_INFO",
                "value": "$service_info_escaped"
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

for name in prober prober-hostnet; do
  # Adapt manifest for the specific ReplicaSet
  m=$manifest
  m=$(
    echo "$m" |
    jq ".metadata.name = \"$name\"" |
    jq ".spec.selector.matchLabels.app = \"$name\"" |
    jq ".spec.template.metadata.labels.app = \"$name\""
  )
  if [[ "$name" = prober-hostnet ]]; then
    m=$(
      echo "$m" |
      jq '.spec.template.spec.hostNetwork = true' |
      jq '.spec.template.spec.dnsPolicy = "ClusterFirstWithHostNet"'
    )
  fi
  file=$(mktemp) && echo "$m" >"$file"
  
  # If the ReplicaSet already exists, update it and then restart the Pod. This
  # occurs if the init Pod has already been running and is restarted.
  if kubectlw get replicaset "$name" 1>/dev/null 2>&1; then
    log "Updating ReplicaSet \"$name\" and restarting Pod..."
    kubectlw apply -f "$file" >/dev/null
    kubectl delete pods -l app="$name" >/dev/null

  # If the ReplicaSet doesn't exist, create it. This occurs if the init Pod
  # runs for the first time.
  else
    log "Creating ReplicaSet \"$name\"..."
    kubectlw apply -f "$file" >/dev/null
  fi
done

log Done
sleep infinity
