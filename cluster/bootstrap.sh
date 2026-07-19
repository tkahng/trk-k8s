#!/usr/bin/env bash
# Cluster bootstrap — runbooks 02+03, encoded. Runs on the LAPTOP.
#
# Provider-agnostic by contract: consumes only the node inventory JSON
# (see cluster/README.md). Works against AWS, Hetzner, or on-prem machines.
#
# Usage:
#   pulumi stack output nodes > /tmp/inventory.json    # or hand-written
#   cluster/bootstrap.sh /tmp/inventory.json ~/.ssh/aws_k8s
#
# Idempotent: skips init/join on nodes that already belong to a cluster.
set -euo pipefail

INV="${1:?usage: bootstrap.sh <inventory.json> <ssh-key>}"
KEY="${2:?usage: bootstrap.sh <inventory.json> <ssh-key>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POD_CIDR="10.244.0.0/16"
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

cp_name=$(jq -r '.[] | select(.role=="control-plane") | .name' "$INV")
cp_public=$(jq -r '.[] | select(.role=="control-plane") | .publicIp' "$INV")
cp_private=$(jq -r '.[] | select(.role=="control-plane") | .privateIp' "$INV")
cp_user=$(jq -r '.[] | select(.role=="control-plane") | .sshUser' "$INV")

run() { # run <user> <host> <cmd...>
  local user="$1" host="$2"; shift 2
  ssh "${SSH_OPTS[@]}" "${user}@${host}" "$@"
}

echo "### Step 0: wait for SSH on all nodes (fresh instances need ~30-60s)"
pids=()
while IFS=$'\t' read -r name public user; do
  (
    for _ in $(seq 1 30); do
      if run "$user" "$public" "true" 2>/dev/null; then
        echo "  ssh ready: $name"
        exit 0
      fi
      sleep 5
    done
    echo "  ssh TIMEOUT after 150s: $name" >&2
    echo "  hint: if ALL nodes time out, the firewall may not admit your current IP" >&2
    echo "        (AWS: make check-ip && make up, then re-run)" >&2
    exit 1
  ) &
  pids+=($!)
done < <(jq -r '.[] | [.name, .publicIp, .sshUser] | @tsv' "$INV")
for p in "${pids[@]}"; do wait "$p"; done

echo "### Step 1: prep all nodes (parallel)"
pids=()
while IFS=$'\t' read -r name public user; do
  (
    scp -q "${SSH_OPTS[@]}" "$REPO_ROOT/cluster/prep-node.sh" "${user}@${public}:/tmp/prep-node.sh"
    run "$user" "$public" "sudo bash /tmp/prep-node.sh $name" > "/tmp/prep-$name.log" 2>&1 \
      && echo "  prep OK: $name" || { echo "  prep FAILED: $name (see /tmp/prep-$name.log)"; exit 1; }
  ) &
  pids+=($!)
done < <(jq -r '.[] | [.name, .publicIp, .sshUser] | @tsv' "$INV")
for p in "${pids[@]}"; do wait "$p"; done

echo "### Step 2: kubeadm init on $cp_name"
if run "$cp_user" "$cp_public" "sudo test -f /etc/kubernetes/admin.conf"; then
  echo "  control plane already initialized — skipping"
else
  run "$cp_user" "$cp_public" "sudo kubeadm init \
    --apiserver-advertise-address=$cp_private \
    --pod-network-cidr=$POD_CIDR \
    --apiserver-cert-extra-sans=$cp_public" > /tmp/kubeadm-init.log 2>&1
  echo "  init OK (log: /tmp/kubeadm-init.log)"
fi

echo "### Step 3: join workers (parallel)"
JOIN_CMD=$(run "$cp_user" "$cp_public" "sudo kubeadm token create --print-join-command" | tr -d '\r')
pids=()
while IFS=$'\t' read -r name public user; do
  (
    if run "$user" "$public" "sudo test -f /etc/kubernetes/kubelet.conf"; then
      echo "  already joined: $name"
    else
      run "$user" "$public" "sudo $JOIN_CMD" > "/tmp/join-$name.log" 2>&1 \
        && echo "  join OK: $name" || { echo "  join FAILED: $name (see /tmp/join-$name.log)"; exit 1; }
    fi
  ) &
  pids+=($!)
done < <(jq -r '.[] | select(.role=="worker") | [.name, .publicIp, .sshUser] | @tsv' "$INV")
for p in "${pids[@]}"; do wait "$p"; done

echo "### Step 4: fetch kubeconfig -> $REPO_ROOT/kubeconfig"
run "$cp_user" "$cp_public" "sudo cat /etc/kubernetes/admin.conf" > "$REPO_ROOT/kubeconfig"
# laptop reaches the API via the public IP (cert SAN covers it)
sed -i '' "s|https://$cp_private:6443|https://$cp_public:6443|" "$REPO_ROOT/kubeconfig" 2>/dev/null \
  || sed -i "s|https://$cp_private:6443|https://$cp_public:6443|" "$REPO_ROOT/kubeconfig"
export KUBECONFIG="$REPO_ROOT/kubeconfig"

echo "### Step 5: install Cilium (CNI)"
if helm status cilium -n kube-system > /dev/null 2>&1; then
  echo "  cilium already installed — skipping"
else
  helm repo add cilium https://helm.cilium.io/ > /dev/null 2>&1 || true
  helm install cilium cilium/cilium --version 1.19.4 \
    --namespace kube-system -f "$REPO_ROOT/cluster/addons/cilium/values.yaml" > /dev/null
fi

echo "### Step 6: wait for all nodes Ready"
kubectl wait --for=condition=Ready node --all --timeout=300s

echo
echo "### Cluster up:"
kubectl get nodes
echo
echo "Next: cluster/platform.sh for storage/ingress/tls/gitops addons."
