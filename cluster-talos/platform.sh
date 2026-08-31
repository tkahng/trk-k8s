#!/usr/bin/env bash
# Session B — the minimal platform on Talos: CNI, storage, CNPG, and the
# restore. Deliberately NOT cluster/platform.sh: no gateway, cert-manager
# issuers, ArgoCD, or NetBox app — those re-prove Phases 5/6.5 rather than
# testing Talos. cert-manager is here ONLY because the barman plugin needs
# it for its internal certificates.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="$REPO_ROOT/kubeconfig-talos"

helm_i() { # helm_i <release> <ns> <chart> [args...] — same retry as platform.sh
  local rel="$1" ns="$2" chart="$3"; shift 3
  if helm status "$rel" -n "$ns" > /dev/null 2>&1; then
    echo "  $rel already installed"; return 0
  fi
  for attempt in 1 2 3; do
    if helm install "$rel" "$chart" -n "$ns" --create-namespace "$@" > /dev/null; then return 0; fi
    [ "$attempt" = 3 ] && { echo "  $rel failed after 3 attempts" >&2; return 1; }
    echo "  $rel attempt $attempt failed — retrying in 20s"
    helm uninstall "$rel" -n "$ns" > /dev/null 2>&1 || true
    sleep 20
  done
}

echo "### cilium (talos flavor: KubePrism, explicit capabilities, cgroup pinned)"
helm repo add cilium https://helm.cilium.io/ > /dev/null 2>&1 || true
helm_i cilium kube-system cilium/cilium --version 1.19.4 \
  -f "$REPO_ROOT/cluster-talos/cilium-values.yaml"
echo "  waiting for nodes Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=300s > /dev/null
kubectl get nodes --no-headers | awk '{print "  "$1, $2}'

echo "### storage: local-path, pointed at /var/mnt/local-path"
# Same provisioner as every era, one Talos-forced change: the default data
# path (/opt/local-path-provisioner) is on the immutable filesystem. The
# kubelet already bind-mounts /var/mnt/local-path (patch-common.yaml);
# point the provisioner's nodePathMap at it.
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.36/deploy/local-path-storage.yaml > /dev/null
# Talos enforces Pod Security admission (baseline) CLUSTER-WIDE by default —
# kubeadm enforced nothing, so this difference was invisible until the
# provisioner's hostPath helper pod was refused outright:
#   violates PodSecurity "baseline:latest": hostPath volumes
# The provisioner namespace must be explicitly privileged. Secure-by-default
# reaches the Kubernetes layer on Talos, not just the OS.
kubectl label ns local-path-storage pod-security.kubernetes.io/enforce=privileged --overwrite > /dev/null
kubectl -n local-path-storage patch configmap local-path-config --type merge \
  -p '{"data":{"config.json":"{\n  \"nodePathMap\": [{\n    \"node\": \"DEFAULT_PATH_FOR_NON_LISTED_NODES\",\n    \"paths\": [\"/var/mnt/local-path\"]\n  }]\n}"}}' > /dev/null
kubectl -n local-path-storage rollout restart deploy/local-path-provisioner > /dev/null
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' > /dev/null 2>&1 || true
echo "  local-path default, data under /var/mnt/local-path"

echo "### cert-manager (barman plugin dependency only — no issuers, no DNS)"
helm repo add jetstack https://charts.jetstack.io > /dev/null 2>&1 || true
helm_i cert-manager cert-manager jetstack/cert-manager --set crds.enabled=true
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s > /dev/null

echo "### cnpg operator + barman cloud plugin"
helm repo add cnpg https://cloudnative-pg.github.io/charts > /dev/null 2>&1 || true
helm_i cnpg-operator cnpg-system cnpg/cloudnative-pg --version 0.29.0
kubectl -n cnpg-system rollout status deploy/cnpg-operator-cloudnative-pg --timeout=180s > /dev/null
kubectl apply --server-side -f \
  https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.14.0/manifest.yaml > /dev/null
kubectl -n cnpg-system rollout status deploy/barman-cloud --timeout=180s > /dev/null
echo "  operator + plugin ready"

echo "### the restore: a database born from the kubeadm era's archive"
kubectl apply -f "$REPO_ROOT/cluster-talos/pg-restore.yaml"
echo "  waiting for recovery (base backup + WAL replay from pg-gen4-20260827)"
for i in $(seq 1 60); do
  ph="$(kubectl -n postgres-cnpg get cluster pg -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$ph" in *"healthy"*) break;; esac
  [ "$i" = 60 ] && { echo "  TIMEOUT waiting for cluster healthy (phase: $ph)" >&2; exit 1; }
  sleep 15
done
echo "  cluster healthy"

echo ""
echo "### VERDICT — did the data outlive the operating system?"
kubectl -n postgres-cnpg exec pg-1 -c postgres -- psql -U postgres -d netbox -qAtc "
select 'vms:      '||count(*) from virtualization_virtualmachine
union all select 'ips:      '||count(*) from ipam_ipaddress
union all select 'prefixes: '||count(*) from ipam_prefix
union all select 'sites:    '||count(*) from dcim_site;"
kubectl -n postgres-cnpg exec pg-1 -c postgres -- psql -U postgres -d netbox -qAtc \
  "select '  '||name from virtualization_virtualmachine order by name;"
echo ""
echo "### archiving under the talos generation (the restore isn't done otherwise)"
kubectl -n postgres-cnpg get cluster pg \
  -o jsonpath='ContinuousArchiving={.status.conditions[?(@.type=="ContinuousArchiving")].status}{"\n"}'
