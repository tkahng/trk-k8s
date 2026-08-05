#!/usr/bin/env bash
# Platform addons — runbooks 04+05, encoded. Runs on the LAPTOP after
# bootstrap.sh. Idempotent.
#
# Secrets come from LOCAL FILES (never git):
#   Cloudflare token: $CF_TOKEN_FILE (default ~/.config/trk-k8s/cloudflare-token)
#   ArgoCD deploy key: ~/.ssh/argocd_trk_k8s
#
# The optional cloud storage addon is chosen by the caller:
#   --provider=azure (default) | aws | none      (on-prem/hetzner -> none)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="$REPO_ROOT/kubeconfig"
CF_TOKEN_FILE="${CF_TOKEN_FILE:-$HOME/.config/trk-k8s/cloudflare-token}"
ARGOCD_KEY="$HOME/.ssh/argocd_trk_k8s"
# Which cloud's OPTIONAL storage addon to install. The cluster layer never
# DETECTS the provider (the inventory contract deliberately doesn't carry
# one) — the caller names it. local-path stays the default StorageClass
# either way, so `none` is a fully working cluster (ADR 002/003).
PROVIDER="${PROVIDER:-azure}"
case "${1:-}" in
  --provider=*) PROVIDER="${1#--provider=}" ;;
  --no-aws)     PROVIDER=none ;;   # back-compat with the pre-Azure flag
esac

helm_i() { # helm_i <release> <ns> <chart> [args...]
  local release="$1" ns="$2" chart="$3"; shift 3
  if helm status "$release" -n "$ns" > /dev/null 2>&1; then
    echo "  $release already installed"
    return 0
  fi
  # Retry loop: on 2-vCPU nodes etcd fsyncs share the disk with image
  # pulls, and the install burst can stall apiserver writes past their
  # timeout (bit three resume sessions in a row — ebs-csi, cert-manager,
  # argocd). A failed install may leave a half-written release record;
  # uninstall it before retrying or the retry hits "name already in use".
  local attempt
  for attempt in 1 2 3; do
    if helm install "$release" "$chart" --namespace "$ns" --create-namespace "$@" > /dev/null; then
      echo "  $release installed"
      return 0
    fi
    echo "  $release install failed (attempt $attempt/3) — cleaning up, retrying in 20s"
    helm uninstall "$release" -n "$ns" > /dev/null 2>&1 || true
    sleep 20
  done
  echo "  ERROR: $release failed after 3 attempts" >&2
  return 1
}

echo "### storage: local-path (default StorageClass)"
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.36/deploy/local-path-storage.yaml > /dev/null
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' > /dev/null 2>&1 || true

case "$PROVIDER" in
  aws)
    echo "### storage: EBS CSI (AWS addon)"
    helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver > /dev/null 2>&1 || true
    helm_i aws-ebs-csi-driver kube-system aws-ebs-csi-driver/aws-ebs-csi-driver
    kubectl apply -f "$REPO_ROOT/cluster/addons/aws-ebs-csi/storageclass.yaml" > /dev/null
    ;;
  azure)
    echo "### storage: Azure Disk CSI (Azure addon)"
    helm repo add azuredisk-csi-driver https://raw.githubusercontent.com/kubernetes-sigs/azuredisk-csi-driver/master/charts > /dev/null 2>&1 || true
    # cloud=AzurePublicCloud + the node's user-assigned managed identity:
    # the driver reaches the Azure API over IMDS with no credential in the
    # cluster — the counterpart to EBS CSI riding the instance profile.
    helm_i azuredisk-csi-driver kube-system azuredisk-csi-driver/azuredisk-csi-driver \
      --set controller.replicas=1 \
      --set linux.kubelet=/var/lib/kubelet
    kubectl apply -f "$REPO_ROOT/cluster/addons/azure-disk-csi/storageclass.yaml" > /dev/null
    ;;
  none)
    echo "### storage: no cloud addon (local-path only)"
    ;;
  *)
    echo "  ERROR unknown provider '$PROVIDER' (want aws|azure|none)" >&2; exit 1 ;;
esac

echo "### metrics-server"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ > /dev/null 2>&1 || true
helm_i metrics-server kube-system metrics-server/metrics-server -f "$REPO_ROOT/cluster/addons/metrics-server/values.yaml"

echo "### cert-manager + Let's Encrypt issuers"
helm repo add jetstack https://charts.jetstack.io > /dev/null 2>&1 || true
helm_i cert-manager cert-manager jetstack/cert-manager -f "$REPO_ROOT/cluster/addons/cert-manager/values.yaml"
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s > /dev/null
if ! kubectl -n cert-manager get secret cloudflare-api-token > /dev/null 2>&1; then
  if [ -f "$CF_TOKEN_FILE" ]; then
    kubectl -n cert-manager create secret generic cloudflare-api-token \
      --from-file=api-token="$CF_TOKEN_FILE" > /dev/null
    echo "  cloudflare-api-token secret created from $CF_TOKEN_FILE"
  else
    echo "  WARNING: no cloudflare token secret and no $CF_TOKEN_FILE —"
    echo "  TLS issuance will fail until you create the secret (runbook 05)."
  fi
fi
kubectl apply -f "$REPO_ROOT/cluster/addons/cert-manager/issuers/letsencrypt.yaml" > /dev/null
echo "  issuers applied"

echo "### gateway (cilium gateway api — the edge, ex ingress-nginx)"
# Cilium's controller (enabled at bootstrap) programs it; cert-manager
# issues the wildcard *.k8s.kahng.dev cert the HTTPS listener references.
kubectl apply -f "$REPO_ROOT/cluster/addons/gateway/gateway.yaml" > /dev/null
echo "  gateway applied"

echo "### postgres credentials (phase 7 — secret from local file, never git)"
PG_PASS_FILE="${PG_PASS_FILE:-$HOME/.config/trk-k8s/postgres-password}"
# 7.3: Patroni needs a second credential — the replication user replicas
# dial the leader with. Same pattern, second file; generated once if absent
# (nobody types this password, only Patroni uses it).
PG_REPL_FILE="${PG_REPL_FILE:-$HOME/.config/trk-k8s/postgres-replication-password}"
if [ ! -f "$PG_REPL_FILE" ]; then
  # tr -d '\n': a trailing newline becomes part of the password via env,
  # but pgpass is line-oriented and silently drops it — the DB then holds
  # password+\n while pg_basebackup sends password. One byte, hours lost.
  (umask 077 && openssl rand -base64 24 | tr -d '\n' > "$PG_REPL_FILE")
  echo "  generated $PG_REPL_FILE"
fi
kubectl get ns postgres > /dev/null 2>&1 || kubectl create ns postgres > /dev/null
if ! kubectl -n postgres get secret postgres-credentials > /dev/null 2>&1; then
  if [ -f "$PG_PASS_FILE" ]; then
    # --from-literal with $(cat): strips trailing newlines that
    # --from-file would faithfully preserve into the secret value
    kubectl -n postgres create secret generic postgres-credentials \
      --from-literal=password="$(cat "$PG_PASS_FILE")" \
      --from-literal=replication-password="$(cat "$PG_REPL_FILE")" > /dev/null
    echo "  postgres-credentials secret created from $PG_PASS_FILE"
  else
    echo "  WARNING: no postgres-credentials secret and no $PG_PASS_FILE —"
    echo "  postgres will sit in CreateContainerConfigError until it exists."
  fi
elif ! kubectl -n postgres get secret postgres-credentials \
    -o jsonpath='{.data.replication-password}' 2>/dev/null | grep -q .; then
  # secret predates 7.3 — add the key without recreating (live clusters)
  kubectl -n postgres patch secret postgres-credentials -p \
    "{\"data\":{\"replication-password\":\"$(printf '%s' "$(cat "$PG_REPL_FILE")" | base64 | tr -d '\n')\"}}" > /dev/null
  echo "  replication-password key added to existing secret"
fi

echo "### argocd + repo credential + applications"
helm repo add argo https://argoproj.github.io/argo-helm > /dev/null 2>&1 || true
helm_i argocd argocd argo/argo-cd
if ! kubectl -n argocd get secret repo-trk-k8s > /dev/null 2>&1; then
  if [ -f "$ARGOCD_KEY" ]; then
    kubectl -n argocd create secret generic repo-trk-k8s \
      --from-literal=type=git \
      --from-literal=url=git@github.com:tkahng/trk-k8s.git \
      --from-file=sshPrivateKey="$ARGOCD_KEY" > /dev/null
    kubectl -n argocd label secret repo-trk-k8s argocd.argoproj.io/secret-type=repository > /dev/null
    echo "  repo credential created"
  else
    echo "  WARNING: $ARGOCD_KEY missing — argocd cannot pull the repo."
  fi
fi
# App-of-apps: ONE imperative apply, ever. The root Application watches
# cluster/gitops/apps/ and creates the rest from git, so a change to an
# Application's spec now takes effect on push instead of needing a hand
# apply (the 7.4 part 1 incident; ADR 007 made this a prerequisite).
kubectl apply -f "$REPO_ROOT/cluster/gitops/root.yaml" > /dev/null
echo "  root application applied (children come from git)"

echo
echo "### Platform restored. MANUAL steps that remain after a rebuild:"
echo "  1. Cloudflare: point *.k8s.kahng.dev at the NEW control-plane public IP"
echo "  2. apps/hello/overlays/dev: update the nip.io host, commit + push"
echo "     (argocd serves the old host until the overlay changes in git)"
echo "  3. argocd admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
