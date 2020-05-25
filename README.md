# Kubernetes connectivity checker

Check the network connectivities inside a cluster. This is useful for testing if a CNI plugin works as expected.

## Tests

The connectivity checker performs the following tests:

- **Pod to itself**
- **Pod to another Pod on the same node**
- **Pod to another Pod on a different node**
- **Pod to its own node**
- **Pod to a different node**
- **Pod to a Service**
- **Pod to the Internet**
- **DNS resolution of a cluster-internal DNS name**
- **DNS resolution of an external DNS name**

All tests are run both from a Pod in the Pod network (normal case) and from a Pod in the host network (that is, running in the same network namespace as the node it's running on).

The tests from the Pod in the host network simulate the connectivities from the node itself (e.g. from a node agent like the kubelet).

The Pods acting as targets of connectivity check always run in the Pod network.

## Usage

Deploy:

```bash
kubectl apply -f https://raw.githubusercontent.com/weibeld/k8s-conncheck/master/k8s-conncheck.yaml
```

View results:

```bash
kubectl -n k8s-conncheck logs rs/prober
kubectl -n k8s-conncheck logs rs/prober-hostnet
```

> You can set `k8s-conncheck` as the default namespace with `kubectl config set-context --current --namespace k8s-conncheck`, so you can omit the `-n k8s-conncheck` flag in the kubectl commands.

Delete:

```bash
kubectl delete -f https://raw.githubusercontent.com/weibeld/k8s-conncheck/master/k8s-conncheck.yaml
```

> Alternatively, you can just delete the `k8s-conncheck` namespace with `kubectl delete ns k8s-conncheck`.
