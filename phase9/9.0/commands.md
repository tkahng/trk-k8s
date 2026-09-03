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

kubeadm join 10.0.1.10:6443 --token eexeuw.q71b1klenr3mz6rx \
 --discovery-token-ca-cert-hash sha256:6df80bc7bd19a674f64c9794816ef06ba27969ce29a5cc10ba6b2d2e5ed72c6c
```

run mkdir,cp,chown on cp.
run join on workers

# install cni

Step 1 — get kubectl working from your laptop. Helm runs from wherever your kubeconfig is, and you don't want to install Helm on the node. From the laptop:

```bash
scp -i ~/.ssh/azure_k8s ubuntu@20.51.163.13:.kube/config ./kubeconfig-9.0
sed -i '' 's/10.0.1.10/20.51.163.13/' ./kubeconfig-9.0
export KUBECONFIG=$PWD/kubeconfig-9.0 && kubectl get nodes
```

The sed is the point: the file says server: <https://10.0.1.10:6443> — the advertise address — which your laptop can't reach. You swap in the public IP, and it works only because you put that IP in --apiserver-cert-extra-sans. That's the flag paying off.

Step 2 — Cilium via Helm. The gotcha: Cilium does not automatically read the --pod-network-cidr you gave kubeadm. Its default IPAM mode (cluster-pool) hands out pod IPs from its own default range, 10.0.0.0/8 — which overlaps your Azure VNet. Pods would get IPs that collide with your nodes. So you must either tell Cilium the CIDR, or tell it to use Kubernetes' per-node allocations (which do come from kubeadm's flag). The second is simpler:

```bash
helm repo add cilium https://helm.cilium.io/ && helm repo update
helm install cilium cilium/cilium --version 1.19.4 --namespace kube-system --set ipam.mode=kubernetes

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

Storage Class

```yaml
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-csi
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: disk.csi.azure.com
parameters:
  skuName: StandardSSD_LRS # available values: StandardSSD_LRS, StandardSSD_ZRS, Premium_LRS, Premium_ZRS, etc.
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```
