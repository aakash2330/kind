# Kubernetes Lab Steps

This is the tested minimal flow for running a small Kubernetes cluster using Docker containers as nodes.

The cluster has:

- `cp0`: one control-plane node
- `worker0`: one worker node
- Flannel: pod networking
- localhost API access: `kubectl` from your Mac can talk to the cluster

Run every Mac-side command from the repo root. The Dockerfile currently pins Kubernetes to `v1.36.1`.

## Before You Start

You need these installed on your Mac:

- Docker or OrbStack
- Docker Compose
- `kubectl`

Quick checks:

```sh
docker version
docker compose version
kubectl version --client
```

Why: Docker runs the fake node machines, Docker Compose starts them consistently, and Mac-side `kubectl` lets you control the cluster without entering `cp0`.

## 0. Start Clean

Run on your Mac:

```sh
docker compose down --remove-orphans
rm -f ./admin.conf
```

Why: removes any old `cp0` or `worker0` containers and deletes the copied kubeconfig, so `kubeadm init` starts from a clean machine.

Important: `kubeadm init` is a one-time command per control-plane container. If you run it twice in the same `cp0`, you will see errors like `Port 6443 is in use` and existing manifest files.

## 1. Build The Node Image

Run on your Mac:

```sh
docker build -t local/k8s-ready:dev .
```

Why: builds the Linux image used by both `cp0` and `worker0`. It contains systemd, containerd, kubelet, kubeadm, kubectl, and required networking tools.

## 2. Start The Control-Plane Container

Run on your Mac:

```sh
docker compose up -d cp0
until docker exec k8s-cp0 systemctl is-active --quiet containerd; do sleep 1; done
docker exec -it k8s-cp0 bash
```

Why: starts a Docker container that behaves like a machine. We enter it because `kubeadm init` must run on the future control-plane node itself.

The wait loop makes sure the container runtime is ready before Kubernetes uses it.

## 3. Initialize The Control Plane

Run inside `cp0`:

```sh
kubeadm init \
  --apiserver-advertise-address=$(hostname -i | awk '{print $1}') \
  --apiserver-cert-extra-sans=127.0.0.1,localhost \
  --pod-network-cidr=10.244.0.0/16
```

Why:

- `kubeadm init` creates the control plane.
- `--apiserver-advertise-address` tells other nodes which `cp0` IP to use.
- `--apiserver-cert-extra-sans=127.0.0.1,localhost` lets your Mac trust the API server when using `https://127.0.0.1:6443`.
- `--pod-network-cidr=10.244.0.0/16` reserves the Pod IP range expected by Flannel.

## 4. Configure kubectl Inside cp0

Run inside `cp0`:

```sh
export KUBECONFIG=/etc/kubernetes/admin.conf
```

Why: tells `kubectl` inside `cp0` how to authenticate to the Kubernetes API server.

Still inside `cp0`, patch kube-proxy so it does not try to change the container host's read-only conntrack limit:

```sh
kubectl -n kube-system get configmap kube-proxy -o yaml \
  | sed 's/maxPerCore: null/maxPerCore: 0/' \
  | sed 's/min: null/min: 0/' \
  | kubectl apply -f -

kubectl -n kube-system rollout restart daemonset/kube-proxy
kubectl -n kube-system rollout status daemonset/kube-proxy --timeout=180s
```

Why: Docker or OrbStack can expose `/proc/sys/net/netfilter/nf_conntrack_max` as read-only inside these node containers. Without this patch, kube-proxy can crash with `permission denied`, and Flannel then cannot reach the Kubernetes Service IP `10.96.0.1`.

## 5. Install Pod Networking

Run inside `cp0`:

```sh
kubectl apply -f https://github.com/flannel-io/flannel/releases/download/v0.28.5/kube-flannel.yml
```

Why: Kubernetes needs a CNI plugin so Pods can get IP addresses and talk across nodes. We use Flannel because it matches the `10.244.0.0/16` Pod CIDR.

## 6. Wait For cp0 To Become Healthy

Run inside `cp0`:

```sh
kubectl wait --for=condition=Ready node/cp0 --timeout=240s
kubectl wait --for=condition=Ready pod --all -A --timeout=300s
kubectl get nodes -o wide
kubectl get pods -A -o wide
```

Why: confirms the control plane and its system Pods are healthy before adding a worker.

## 7. Prepare kubectl On Your Mac

Open a new Mac terminal and run:

```sh
docker cp k8s-cp0:/etc/kubernetes/admin.conf ./admin.conf
kubectl --kubeconfig ./admin.conf config set-cluster kubernetes --server=https://127.0.0.1:6443
kubectl --kubeconfig ./admin.conf get nodes
```

Why: copies the cluster admin kubeconfig to your Mac, then rewrites the API server address to the localhost port exposed by Docker Compose.

From this point, Mac-side commands can use:

```sh
kubectl --kubeconfig ./admin.conf ...
```

## 8. Create The Worker Join Command

Run inside `cp0`:

```sh
kubeadm token create --print-join-command
```

Why: prints the secure `kubeadm join ...` command that lets `worker0` join this exact cluster.

Copy the full output.

## 9. Start The Worker Container

Run on your Mac:

```sh
docker compose up -d worker0
until docker exec k8s-worker0 systemctl is-active --quiet containerd; do sleep 1; done
docker exec -it k8s-worker0 bash
```

Why: starts the second Docker container, which will become a Kubernetes worker node.

The wait loop avoids joining the worker before its container runtime has finished starting.

## 10. Join worker0 To The Cluster

Run inside `worker0`:

```sh
kubeadm join 192.168.x.x:6443 --token ... --discovery-token-ca-cert-hash sha256:...
```

Use the exact command printed by `kubeadm token create --print-join-command`.

Why: `worker0` contacts the control-plane API server and registers itself as a node.

## 11. Verify Both Nodes

Run on your Mac:

```sh
kubectl --kubeconfig ./admin.conf wait --for=condition=Ready node/worker0 --timeout=240s
kubectl --kubeconfig ./admin.conf wait --for=condition=Ready pod --all -A --timeout=300s
kubectl --kubeconfig ./admin.conf get nodes -o wide
kubectl --kubeconfig ./admin.conf get pods -A -o wide
```

Why: confirms the control plane sees `worker0`, and all cluster system Pods are healthy.

You want:

- `cp0` is `Ready`
- `worker0` is `Ready`
- Flannel is running on both nodes
- CoreDNS is running
- restarts are `0`

## 12. Test DNS

Run on your Mac:

```sh
kubectl --kubeconfig ./admin.conf run dns-test \
  --image=busybox:1.36 \
  --restart=Never \
  --command -- \
  sh -c "nslookup kubernetes.default.svc.cluster.local"

kubectl --kubeconfig ./admin.conf wait --for=jsonpath='{.status.phase}'=Succeeded pod/dns-test --timeout=180s
kubectl --kubeconfig ./admin.conf logs dns-test
kubectl --kubeconfig ./admin.conf delete pod dns-test --wait=true
```

Why: creates a temporary Pod and checks that Kubernetes DNS can resolve the built-in `kubernetes` Service.

## 13. Test A Normal App And Service

Run on your Mac:

```sh
kubectl --kubeconfig ./admin.conf create deployment smoke-nginx --image=nginx:1.27-alpine
kubectl --kubeconfig ./admin.conf rollout status deployment/smoke-nginx --timeout=240s
kubectl --kubeconfig ./admin.conf expose deployment smoke-nginx --port=80 --target-port=80
```

Why:

- the Deployment proves Kubernetes can run a normal application Pod
- the Service gives that app a stable cluster DNS name

Now test the Service from another Pod:

```sh
kubectl --kubeconfig ./admin.conf run curl-test \
  --image=curlimages/curl:8.11.1 \
  --restart=Never \
  --command -- \
  curl --retry 20 --retry-all-errors --retry-delay 1 -fsS http://smoke-nginx.default.svc.cluster.local

kubectl --kubeconfig ./admin.conf wait --for=jsonpath='{.status.phase}'=Succeeded pod/curl-test --timeout=240s
kubectl --kubeconfig ./admin.conf logs curl-test | head
```

Why: this proves Pod-to-Service networking works. The retry handles the short delay while Kubernetes programs Service routing.

## 14. Clean Up The Test App

Run on your Mac:

```sh
kubectl --kubeconfig ./admin.conf delete pod curl-test --wait=true
kubectl --kubeconfig ./admin.conf delete service smoke-nginx --wait=true
kubectl --kubeconfig ./admin.conf delete deployment smoke-nginx --wait=true
kubectl --kubeconfig ./admin.conf wait --for=delete pod -l app=smoke-nginx --timeout=120s
kubectl --kubeconfig ./admin.conf get pods -A
```

Why: removes the temporary app and client Pod, leaving only the Kubernetes system components.

## 15. Tear Down The Lab

Run on your Mac:

```sh
docker compose down --remove-orphans
rm -f ./admin.conf
```

Why: removes the node containers and local kubeconfig so the next run starts cleanly.

## Quick Mental Model

```text
kubectl -> API server -> scheduler/controller-manager -> node kubelet -> containerd -> containers
```

In this lab:

- `cp0` runs the control plane and also can run Pods.
- `worker0` runs workload Pods.
- `containerd` is the container runtime inside each node container.
- `kubelet` is the node agent that asks containerd to run Pod containers.
- Flannel gives Pods their cross-node network.
- CoreDNS gives Services names like `smoke-nginx.default.svc.cluster.local`.
