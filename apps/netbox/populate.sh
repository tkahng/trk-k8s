#!/usr/bin/env bash
# Populate NetBox with THIS cluster's own infrastructure.
#
# The point of the capstone (docs/notes/capstone-scope.md): NetBox beat
# Saleor because its data is your real VPC, subnets and nodes — data you'd
# be annoyed to lose. That is what turns the restore drill from a mechanical
# exercise into one that matters, and it's the premise Phase 8 needs.
#
# Everything is DISCOVERED, never hardcoded: node inventory from the Pulumi
# contract, CIDRs from kubeadm-config, versions from the live nodes. So
# re-running after a rebuild records the new reality rather than replaying
# a stale snapshot — which is itself the lesson about what "real data" means
# when the cluster is cattle.
#
# Idempotent: NetBox has no upsert, so every object is GET-by-key then
# POSTed only if absent. Safe to re-run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/kubeconfig}"
NS=netbox
PORT="${PORT:-18080}"

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

echo "### discovering the cluster"
NODES_JSON="$(cd "$REPO_ROOT/infra/azure" && "$REPO_ROOT/infra/azure/pulumi.sh" stack output nodes 2>/dev/null)"
[ -n "$NODES_JSON" ] || { echo "no node inventory from pulumi" >&2; exit 1; }

KUBEADM="$(kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null)"
POD_CIDR="$(printf '%s' "$KUBEADM" | awk '/podSubnet:/{print $2}')"
SVC_CIDR="$(printf '%s' "$KUBEADM" | awk '/serviceSubnet:/{print $2}')"
K8S_VER="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"
LOCATION="$(cd "$REPO_ROOT/infra/azure" && "$REPO_ROOT/infra/azure/pulumi.sh" config get azure-native:location 2>/dev/null || echo eastus)"
# The VNet/subnet the nodes actually sit in — derived from the contract's
# private IPs rather than assumed.
SUBNET_CIDR="$(printf '%s' "$NODES_JSON" | jq -r '.[0].privateIp' | awk -F. '{print $1"."$2"."$3".0/24"}')"
VNET_CIDR="$(printf '%s' "$NODES_JSON" | jq -r '.[0].privateIp' | awk -F. '{print $1"."$2".0.0/16"}')"
echo "  location=$LOCATION k8s=$K8S_VER vnet=$VNET_CIDR subnet=$SUBNET_CIDR pods=$POD_CIDR svc=$SVC_CIDR"

echo "### opening a port-forward to netbox"
# Via port-forward rather than the public URL: this works before DNS is
# repointed after a rebuild, and doesn't depend on the NSG admitting us.
kubectl -n "$NS" port-forward svc/netbox "$PORT":80 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  curl -sf "http://localhost:$PORT/api/" >/dev/null 2>&1 && break
  sleep 2
done
curl -sf "http://localhost:$PORT/api/" >/dev/null || { echo "netbox API unreachable" >&2; exit 1; }

TOKEN="$(kubectl -n "$NS" get secret netbox-superuser -o jsonpath='{.data.api_token}' | base64 -d)"
API="http://localhost:$PORT/api"
AUTH=(-H "Authorization: Token $TOKEN" -H "Content-Type: application/json")

# get_or_create <endpoint> <query> <json-body> -> prints the object id
gc() {
  local ep="$1" q="$2" body="$3" id
  id="$(curl -sf "${AUTH[@]}" "$API/$ep/?$q" | jq -r '.results[0].id // empty')"
  if [ -z "$id" ]; then
    id="$(curl -sf "${AUTH[@]}" -X POST "$API/$ep/" -d "$body" | jq -r '.id // empty')"
    [ -n "$id" ] && echo "  + $ep $q" >&2
  fi
  printf '%s' "$id"
}

echo "### sites and cluster"
SITE=$(gc "dcim/sites" "slug=azure-$LOCATION" \
  "$(jq -nc --arg n "Azure $LOCATION" --arg s "azure-$LOCATION" \
     '{name:$n,slug:$s,status:"active",description:"Azure region hosting the trk-k8s learning cluster"}')")
CTYPE=$(gc "virtualization/cluster-types" "slug=kubeadm-azure" \
  '{"name":"kubeadm on Azure","slug":"kubeadm-azure","description":"Self-managed kubeadm, not AKS (ADR 003: no cloud-controller-manager)"}')
CLUSTER=$(gc "virtualization/clusters" "name=trk-k8s" \
  "$(jq -nc --argjson t "$CTYPE" --argjson s "$SITE" --arg d "kubeadm $K8S_VER, Cilium eBPF (kube-proxy-free), Gateway API edge" \
     '{name:"trk-k8s",type:$t,scope_type:"dcim.site",scope_id:$s,status:"active",description:$d}')")

echo "### prefixes (the address plan, identical across all three providers)"
add_prefix() {
  gc "ipam/prefixes" "prefix=$1" \
    "$(jq -nc --arg p "$1" --arg d "$2" --argjson s "$SITE" \
       '{prefix:$p,status:"active",description:$d,scope_type:"dcim.site",scope_id:$s}')" >/dev/null
}
add_prefix "$VNET_CIDR"   "Azure VNet vnet-trk-k8s"
add_prefix "$SUBNET_CIDR" "snet-nodes — the only subnet; nodes at .10/.11/.12"
add_prefix "$POD_CIDR"    "Cilium pod CIDR (cluster-pool). Pinned to match kubeadm --pod-network-cidr; Cilium's 10.0.0.0/8 default would collide with the VNet"
add_prefix "$SVC_CIDR"    "Kubernetes service CIDR — eBPF-translated, no kube-proxy"

echo "### virtual machines, from the inventory contract"
echo "$NODES_JSON" | jq -c '.[]' | while read -r n; do
  NAME=$(jq -r .name <<<"$n"); ROLE=$(jq -r .role <<<"$n")
  PRIV=$(jq -r .privateIp <<<"$n"); PUB=$(jq -r .publicIp <<<"$n")
  VCPU=$(kubectl get node "$NAME" -o jsonpath='{.status.capacity.cpu}' 2>/dev/null || echo 2)
  MEMKB=$(kubectl get node "$NAME" -o jsonpath='{.status.capacity.memory}' 2>/dev/null | tr -d 'Ki')
  MEMMB=$(( ${MEMKB:-4194304} / 1024 ))
  OS=$(kubectl get node "$NAME" -o jsonpath='{.status.nodeInfo.osImage}' 2>/dev/null)

  VM=$(gc "virtualization/virtual-machines" "name=$NAME" \
    "$(jq -nc --arg nm "$NAME" --argjson c "$CLUSTER" --argjson v "$VCPU" --argjson m "$MEMMB" \
        --arg d "$ROLE · $OS · kubelet $K8S_VER" \
        '{name:$nm,cluster:$c,status:"active",vcpus:$v,memory:$m,description:$d}')")
  IF=$(gc "virtualization/interfaces" "virtual_machine_id=$VM&name=eth0" \
    "$(jq -nc --argjson vm "$VM" '{virtual_machine:$vm,name:"eth0",enabled:true,description:"Azure NIC (nic-*) — private + public IP"}')")
  for pair in "$PRIV/24:private, kubelet/etcd/VXLAN ride this" "$PUB/32:public — SSH/6443/30080/30443 admitted only from the admin IP"; do
    ADDR="${pair%%:*}"; DESC="${pair#*:}"
    gc "ipam/ip-addresses" "address=$ADDR" \
      "$(jq -nc --arg a "$ADDR" --argjson i "$IF" --arg d "$DESC" \
         '{address:$a,status:"active",assigned_object_type:"virtualization.vminterface",assigned_object_id:$i,description:$d}')" >/dev/null
  done
done

echo
echo "### done. Counts now in NetBox:"
for ep in dcim/sites virtualization/clusters virtualization/virtual-machines ipam/prefixes ipam/ip-addresses; do
  printf '  %-34s %s\n' "$ep" "$(curl -sf "${AUTH[@]}" "$API/$ep/?limit=1" | jq -r '.count')"
done
