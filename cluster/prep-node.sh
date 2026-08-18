#!/usr/bin/env bash
# Node preparation — runbook 02 Part A, encoded. Runs ON a node, as root.
# Usage: prep-node.sh <node-name>
# Idempotent: safe to re-run on an already-prepped node.
set -euo pipefail

NODE_NAME="${1:?usage: prep-node.sh <node-name>}"
# Bumped to v1.36 after Drill 2 (2026-07-15) — rebuilds must not downgrade.
# When v1.37 ships, the upgrade lab can run again before bumping this.
K8S_MINOR="v1.36"

echo "=== [$NODE_NAME] A1: hostname"
hostnamectl set-hostname "$NODE_NAME"

echo "=== [$NODE_NAME] A2: verify swap is off"
if [ -n "$(swapon --show)" ]; then
  echo "ERROR: swap is enabled; disable it (swapoff -a + /etc/fstab)" >&2
  exit 1
fi

echo "=== [$NODE_NAME] A3: kernel modules and sysctls"
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay br_netfilter

cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system > /dev/null

echo "=== [$NODE_NAME] A3.5: apt mirror reachability"
# Cloud images pin apt to a cloud-local mirror (azure.archive.ubuntu.com,
# <region>.ec2.archive.ubuntu.com) — and that mirror can be dead FROM INSIDE
# the cloud while the global archive answers fine. Hit on Azure 2026-08-17:
# the regional mirror timed out on port 80 from every node, failing prep on
# a fresh cluster. If the configured mirror doesn't answer, fall back to the
# global archive: slower, but never a single-cloud point of failure.
# noble uses deb822 (/etc/apt/sources.list.d/ubuntu.sources); older images
# use sources.list — handle both.
MIRROR="$(grep -rhoE 'https?://[a-z0-9.-]*archive\.ubuntu\.com' \
  /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null | sort -u | head -1)"
if command -v curl >/dev/null && [ -n "$MIRROR" ] && [ "${MIRROR#*//}" != "archive.ubuntu.com" ]; then
  if ! curl -sf -m 8 -o /dev/null "$MIRROR/ubuntu/"; then
    echo "  mirror $MIRROR unreachable — falling back to archive.ubuntu.com"
    sed -i "s|${MIRROR#*//}|archive.ubuntu.com|g" \
      /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true
  else
    echo "  mirror $MIRROR ok"
  fi
fi

echo "=== [$NODE_NAME] A4: containerd"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
# kubelet and runtime MUST agree on the cgroup manager (systemd on Ubuntu)
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
# align the sandbox (pause) image with what kubeadm expects
sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10"|' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd > /dev/null 2>&1

echo "=== [$NODE_NAME] A5: kubeadm, kubelet, kubectl, crictl"
apt-get install -yq apt-transport-https ca-certificates curl gpg
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -q
apt-get install -yq kubelet kubeadm kubectl cri-tools
apt-mark hold kubelet kubeadm kubectl > /dev/null

cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
EOF

echo "=== [$NODE_NAME] prep complete"
