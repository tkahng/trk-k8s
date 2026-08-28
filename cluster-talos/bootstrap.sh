#!/usr/bin/env bash
# Phase 8 — bring up Kubernetes on Talos. This script REPLACES
# cluster/prep-node.sh + cluster/bootstrap.sh entirely, which is the
# headline finding of the phase: the provider seam survived three cloud
# swaps untouched, but an OS swap rewrites the whole cluster/ layer.
#
# What has no equivalent here:
#   - prep-node.sh (hostname, swap, modules, sysctls, containerd, apt):
#     Talos ships an immutable image with all of it baked in. There is no
#     package manager, no swap to disable, and no apt mirror to be
#     unreachable — the failure that cost us two bring-ups on Ubuntu.
#   - kubeadm init / join: replaced by machine configs + one bootstrap RPC.
#   - SSH: there is none. Everything below happens over the API on :50000.
#
# Usage:  cluster-talos/bootstrap.sh <inventory.json>
# The inventory is the SAME contract every provider exports (its sshUser
# field is carried but meaningless here — see infra/azure-talos/main.go).
set -euo pipefail

INV="${1:?usage: bootstrap.sh <inventory.json>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HOME/.config/trk-k8s/talos"
CLUSTER_NAME="trk-k8s-talos"

command -v talosctl >/dev/null || {
  echo "talosctl not installed. brew install siderolabs/tap/talosctl" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

CP_PUB="$(jq -r '.[] | select(.role=="control-plane").publicIp' "$INV")"
CP_PRIV="$(jq -r '.[] | select(.role=="control-plane").privateIp' "$INV")"
WORKER_PUBS=$(jq -r '.[] | select(.role=="worker").publicIp' "$INV")
# Every public IP, for certificate SANs. On Azure the public address is
# NAT — the node never sees it on its own NIC — so nothing ends up in the
# certs by default and talosctl/kubectl from the laptop fail TLS against
# the public endpoint. Exactly the problem kubeadm solved with
# --apiserver-cert-extra-sans in Phase 2, arriving again in Talos clothes.
# Cost us a 10-minute bootstrap timeout before it was diagnosed.
ALL_PUBS="$(jq -r '[.[].publicIp] | join(",")' "$INV")"

echo "### Step 0: wait for the Talos API on every node (maintenance mode)"
# The machines boot UNCONFIGURED and listen on 50000 waiting to be told
# what they are. `talosctl version` against an unconfigured node needs
# --insecure: there is no shared CA yet, because we have not generated one.
for ip in $CP_PUB $WORKER_PUBS; do
  for i in $(seq 1 60); do
    if talosctl -n "$ip" version --insecure --short > /dev/null 2>&1; then
      echo "  talos api ready: $ip"; break
    fi
    [ "$i" = 60 ] && { echo "  TIMEOUT waiting for talos api on $ip" >&2; exit 1; }
    sleep 5
  done
done

echo "### Step 1: generate machine configs"
# Generated ONCE and kept in ~/.config/trk-k8s/talos — they embed the
# cluster CA and secrets, exactly like kubeadm's PKI. Same rule as every
# other credential in this project: local file, never git.
mkdir -p "$OUT"
# Regenerate whenever the current control-plane public IP is not already a
# SAN in the existing config: a rebuild hands out new public IPs, and stale
# certs fail in a way (bootstrap timeout) that does not name its cause.
if [ -f "$OUT/controlplane.yaml" ] && grep -q "$CP_PUB" "$OUT/controlplane.yaml"; then
  echo "  configs exist and match the current IPs — reusing"
else
  [ -d "$OUT" ] && mv "$OUT" "$OUT.$(date +%s).bak"
  (umask 077 && talosctl gen config "$CLUSTER_NAME" "https://${CP_PRIV}:6443" \
    --output-dir "$OUT" \
    --additional-sans "$ALL_PUBS" \
    --config-patch @"$REPO_ROOT/cluster-talos/patch-common.yaml" > /dev/null)
  echo "  generated controlplane.yaml, worker.yaml, talosconfig (SANs: $ALL_PUBS)"
fi

echo "### Step 2: apply config to the control plane"
talosctl -n "$CP_PUB" apply-config --insecure --file "$OUT/controlplane.yaml"
echo "  applied — node will reboot into its configured role"

echo "### Step 3: apply config to workers (parallel)"
for ip in $WORKER_PUBS; do
  talosctl -n "$ip" apply-config --insecure --file "$OUT/worker.yaml" &
done
wait
echo "  applied to all workers"

export TALOSCONFIG="$OUT/talosconfig"
talosctl config endpoint "$CP_PUB"
talosctl config node "$CP_PUB"

echo "### Step 4: bootstrap etcd (ONCE, on one node only)"
# The kubeadm analogue of `kubeadm init`, reduced to a single RPC. Retried
# because the node is rebooting into its new role and the API returns
# "not ready" until it is up with the config applied.
for i in $(seq 1 60); do
  if talosctl bootstrap 2>/dev/null; then echo "  etcd bootstrapped"; break; fi
  [ "$i" = 60 ] && { echo "  TIMEOUT: bootstrap never succeeded" >&2; exit 1; }
  sleep 10
done

echo "### Step 5: fetch kubeconfig -> $REPO_ROOT/kubeconfig-talos"
for i in $(seq 1 40); do
  if talosctl kubeconfig "$REPO_ROOT/kubeconfig-talos" --force > /dev/null 2>&1; then
    echo "  kubeconfig written"; break
  fi
  [ "$i" = 40 ] && { echo "  TIMEOUT: kubeconfig never issued" >&2; exit 1; }
  sleep 10
done
# The generated kubeconfig points at the PRIVATE endpoint; rewrite to the
# public IP so kubectl works from the laptop (same fix as `make kubeconfig`).
sed -i '' "s|https://${CP_PRIV}:6443|https://${CP_PUB}:6443|" "$REPO_ROOT/kubeconfig-talos" 2>/dev/null || true

echo ""
echo "### Talos cluster up. Nodes will be NotReady until Cilium is installed:"
KUBECONFIG="$REPO_ROOT/kubeconfig-talos" kubectl get nodes 2>/dev/null || true
echo ""
echo "Next: cluster-talos/platform.sh (Cilium with KubePrism, then the CNPG restore)"
echo "  export TALOSCONFIG=$OUT/talosconfig    # for talosctl"
echo "  export KUBECONFIG=$REPO_ROOT/kubeconfig-talos"
