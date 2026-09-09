# prep

for each node

```bash
# --- container runtime ---
sudo apt-get update && sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd

# --- kernel modules + sysctls ---
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# --- swap off (now and after reboot) ---
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# --- kubernetes packages, pinned to the v1.36 minor ---
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet

# --- hetzner only: two NICs, make kubelet register the private one ---
# .10 cp-1, .11 worker-1, .12 worker-2 (see make nodes)
echo 'KUBELET_EXTRA_ARGS=--node-ip=10.0.1.10' > /etc/default/kubelet
systemctl restart kubelet
```

# init

on cp1

```bash
sudo kubeadm init \
  --apiserver-advertise-address=<cp-ip-private> \
  --apiserver-cert-extra-sans=<cp-ip-public> \
  --pod-network-cidr=10.244.0.0/16

```

```bash
To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

Alternatively, if you are the root user, you can run:

  export KUBECONFIG=/etc/kubernetes/admin.conf

You should now deploy a pod network to the cluster.
Run "kubectl apply -f [podnetwork].yaml" with one of the options listed at:
  https://kubernetes.io/docs/concepts/cluster-administration/addons/

Then you can join any number of worker nodes by running the following on each as root:

kubeadm join 10.0.1.10:6443 --token zgijtd.zevevhru5hd711wr \
 --discovery-token-ca-cert-hash sha256:8b700aa31f84a59983cad724888ba6ed0622d9c3ed754ccc078371066ed96bff
```

run mkdir,cp,chown on cp.
run join on workers

# hetzner network notes

The ELI5. Every Hetzner server is a house with two doors: the front door onto the public street (eth0, with a bouncer — the firewall), and the back door onto a private courtyard only your three houses share (enp7s0, 10.0.1.x). Three things go wrong: the back door has no handle (NIC exists but unconfigured), each house introduces itself by its front-door address (kubelet registers the public IP, so cp-1's packages get turned away by worker-1's bouncer), and the back door is narrower (1450-byte path, Cilium assumes 1500, big packets jam). AWS/Azure houses have one door, so none of it comes up.

The steps, memorable as four words — look, handle, name, width:

1. Look: ip -4 -brief addr — do you see enp7s0 10.0.1.x?
2. Handle (only if not): netplan enp7s0: dhcp4: true, netplan apply
3. Name: KUBELET_EXTRA_ARGS=--node-ip=10.0.1.x in /etc/default/kubelet, before init/join
4. Width: --set MTU=1400 on the Cilium install

# install cni

Step 1 — get kubectl working from your laptop. Helm runs from wherever your kubeconfig is, and you don't want to install Helm on the node. From the laptop:

```bash
scp -i ~/.ssh/hetzner_k8s root@49.12.65.53:.kube/config ./kubeconfig-9.0
sed -i '' 's/10.0.1.10/49.12.65.53/' ./kubeconfig-9.0
export KUBECONFIG=$PWD/kubeconfig-9.0 && kubectl get nodes -o wide
```

The sed is the point: the file says server: <https://10.0.1.10:6443> — the advertise address — which your laptop can't reach. You swap in the public IP, and it works only because you put that IP in --apiserver-cert-extra-sans. That's the flag paying off.

Step 2 — Cilium via Helm. The gotcha: Cilium does not automatically read the --pod-network-cidr you gave kubeadm. Its default IPAM mode (cluster-pool) hands out pod IPs from its own default range, 10.0.0.0/8 — which overlaps your Azure VNet. Pods would get IPs that collide with your nodes. So you must either tell Cilium the CIDR, or tell it to use Kubernetes' per-node allocations (which do come from kubeadm's flag). The second is simpler:

```bash
# export KUBECONFIG=$PWD/kubeconfig-9.0
helm repo add cilium https://helm.cilium.io/ && helm repo update
helm install cilium cilium/cilium --version 1.19.4 --namespace kube-system --set ipam.mode=kubernetes --set MTU=1400
# - AWS: one NIC, MTU 9001 inside the VPC. Cilium measures it, subtracts 50, pods get plenty. Leave it unset.
# - Azure: one NIC, MTU 1500. Same story, pods get 1450, correct. Leave it unset.
# - Hetzner: Cilium measures eth0 (1500) but pod traffic rides enp7s0 (1450). The guess is 50 bytes too generous. Override to 1400.
```

Then watch: kubectl get pods -n kube-system -w until the cilium pods are Running, and kubectl get nodes flips to Ready. That's the moment the middle paragraph of your init output was about.

(Your repo's values file solves the CIDR problem the other way — pinning cluster-pool to 10.244.0.0/16 — and also turns off kube-proxy for Gateway API, which we skipped. Both go in the diff, not in tonight's scope.)

# install csi

```bash
helm repo add azuredisk-csi-driver https://raw.githubusercontent.com/kubernetes-sigs/azuredisk-csi-driver/master/charts && helm repo update

helm install azuredisk-csi-driver azuredisk-csi-driver/azuredisk-csi-driver --namespace kube-system --set controller.replicas=1

helm upgrade azuredisk-csi-driver azuredisk-csi-driver/azuredisk-csi-driver --namespace kube-system --set controller.replicas=1 --set controller.allowEmptyCloudConfig=true

kubectl get pods -n kube-system | grep csi
```

# install csi — hetzner (2026-09-08)

Hetzner has no instance identity, so the driver needs the project API
token as a Secret — the first cloud credential that lives inside the
cluster. The chart looks for Secret `hcloud`, key `token`, in its namespace.

```bash
kubectl -n kube-system create secret generic hcloud --from-file=token=$HOME/.config/trk-k8s/hcloud-token

helm repo add hcloud https://charts.hetzner.cloud && helm repo update

# storageClasses=[] : don't let the chart create its own default class — we write ours
helm install hcloud-csi hcloud/hcloud-csi --namespace kube-system --set-json 'storageClasses=[]'

kubectl -n kube-system get pods | grep hcloud-csi   # 1 controller + 1 node pod per node, Running
```

# Storage Class

```yaml
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: hcloud-csi
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: csi.hetzner.cloud
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```
