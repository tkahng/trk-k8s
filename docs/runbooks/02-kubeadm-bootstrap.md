# Runbook 02 — Bootstrap Kubernetes with kubeadm

Turns three Ubuntu 24.04 machines (from any `infra/<provider>` stack, or
on-prem) into a cluster: 1 control plane + 2 workers. Provider-agnostic by
design (ADR 002): everything here uses only the node inventory — no cloud
APIs, no cloud-provider flag (ADR 003).

Prereqs: `make up` done, `make nodes` shows the inventory, SSH works.

Conventions: run **[all]** steps on every node, **[cp]** only on the control
plane, **[workers]** only on workers. `make ssh-cp` / `make ssh-worker-1` /
`make ssh-worker-2` to get shells.

Versions: Kubernetes **v1.35** (deliberately one minor behind latest so the
Phase 6 upgrade lab has somewhere to go — check <https://kubernetes.io/releases/>),
containerd from Ubuntu's repo.

---

## Part A — Node preparation [all]

### A1. Hostname = node name

kubeadm registers each node under its hostname. Set the inventory names so
`kubectl get nodes` reads like our docs:

```sh
sudo hostnamectl set-hostname k8s-cp-1     # or k8s-worker-1 / k8s-worker-2
```

### A2. Verify swap is off

The kubelet historically refuses to run with swap enabled (memory accounting
for pods becomes unreliable). Cloud images ship without swap — verify:

```sh
swapon --show   # no output = good
```

### A3. Kernel modules and sysctls

Container traffic crosses Linux bridges and gets NATed; the kernel must be
told to (a) load the overlay filesystem module (containerd's snapshotter) and
br_netfilter (makes bridged traffic visible to iptables), and (b) forward IP
traffic — a Linux box is not a router by default, but a k8s node is one:

```sh
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay br_netfilter

cat <<'EOF' | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
```

### A4. containerd (the container runtime)

The kubelet doesn't run containers itself — it talks CRI (Container Runtime
Interface) to a runtime. We use containerd:

```sh
sudo apt-get update
sudo apt-get install -y containerd
```

Generate the full default config, then make **two required edits**:

```sh
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
```

1. `SystemdCgroup = true` — Ubuntu boots with systemd as the cgroup manager;
   kubelet and the runtime MUST agree on who manages cgroups or pods die
   randomly under memory pressure. This is the single most classic kubeadm
   misconfiguration:

```sh
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
```

1. Pause image version — align containerd's sandbox image with what kubeadm
   expects (silences a kubeadm warning; the pause container is the tiny
   process that holds each pod's network namespace open):

```sh
sudo sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10"|' /etc/containerd/config.toml
```

```sh
sudo systemctl restart containerd && sudo systemctl enable containerd
```

### A5. kubeadm, kubelet, kubectl

From the official pkgs.k8s.io repo (per-minor-version repos):

```sh
K8S_MINOR=v1.35
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl cri-tools
sudo apt-mark hold kubelet kubeadm kubectl   # upgrades must be deliberate (Phase 6 lab)
```

`cri-tools` provides `crictl` (docker-ps-but-for-CRI — how you inspect
containers on a k8s node). Point it at containerd's socket:

```sh
cat <<'EOF' | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
EOF
```

The kubelet now crash-loops ("waiting for config") — **expected**: kubeadm
hasn't given it a cluster yet.

---

## Part B — Control plane [cp]

### B1. kubeadm init

```sh
PUBLIC_IP=<this node's public IP from `make nodes`>
sudo kubeadm init \
  --apiserver-advertise-address=10.0.1.10 \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-cert-extra-sans=${PUBLIC_IP}
```

Why each flag:

- `--apiserver-advertise-address=10.0.1.10` — cluster-internal traffic stays
  on the private network; etcd binds here, workers join here.
- `--pod-network-cidr=10.244.0.0/16` — the pod address space, handed to
  Cilium in Phase 3. Must NOT overlap the VPC (10.0.0.0/16) — note Cilium's
  own default pool (10.0.0.0/8) would overlap, so we'll configure it
  explicitly to use this range.
- `--apiserver-cert-extra-sans=<public IP>` — the API server's TLS cert must
  name every address clients use. kubectl from the laptop connects via the
  public IP; without this SAN, TLS verification fails. (Public IP changes on
  every rebuild — this flag is why the runbook needs the current one.)

**Save the `kubeadm join ...` command it prints.** (Recoverable anytime with
`kubeadm token create --print-join-command`; tokens expire after 24h.)

### B2. What just happened (read before continuing)

`kubeadm init` did, in order: generated a CA + certs in `/etc/kubernetes/pki`;
wrote static-pod manifests to `/etc/kubernetes/manifests/` (etcd, apiserver,
controller-manager, scheduler — the kubelet runs these directly from disk, no
scheduler involved: that's how the control plane hosts itself); wrote
kubeconfigs to `/etc/kubernetes/`; uploaded cluster config to a ConfigMap;
created the bootstrap token; installed CoreDNS + kube-proxy as addons.

Look around:

```sh
ls /etc/kubernetes/manifests/ /etc/kubernetes/pki/
sudo crictl ps   # the control plane, as containers
```

### B3. kubectl access

On the node:

```sh
mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown $(id -u):$(id -g) ~/.kube/config
kubectl get nodes   # k8s-cp-1 NotReady — expected: no CNI yet (Phase 3)
```

From the laptop (repo root): copy the kubeconfig and point it at the public IP:

```sh
scp -i ~/.ssh/aws_k8s ubuntu@${PUBLIC_IP}:.kube/config ./kubeconfig
sed -i '' "s|https://10.0.1.10:6443|https://${PUBLIC_IP}:6443|" ./kubeconfig
KUBECONFIG=./kubeconfig kubectl get nodes
```

(`kubeconfig` is gitignored — it contains the cluster admin key.)

---

## Part C — Join workers [workers]

Paste the saved join command on each worker:

```sh
sudo kubeadm join 10.0.1.10:6443 --token <t> --discovery-token-ca-cert-hash sha256:<h>
```

The trust model, both directions: the worker verifies it's talking to the real
cluster by pinning the CA public key (`--discovery-token-ca-cert-hash`); the
cluster verifies the worker via the short-lived bootstrap `--token`. The
kubelet then submits a CSR, gets a client cert signed by the cluster CA, and
that becomes its permanent identity.

---

## Part D — Verify

```sh
kubectl get nodes -o wide      # all 3 registered, all NotReady (no CNI — correct!)
kubectl get pods -A            # coredns Pending (needs pod network), rest Running
kubectl get pods -A -o wide    # note: control-plane pods run on host network — that's why they're fine without a CNI
```

Done when: 3 nodes registered, control-plane pods healthy, CoreDNS Pending.
**NotReady is the success state of this runbook** — Phase 3 (Cilium) makes
them Ready.

## Teardown note

`make destroy` erases the machines and thus the cluster. There is no state to
preserve yet — rebuilding means re-running this runbook (Phase 6 automates
exactly that).
