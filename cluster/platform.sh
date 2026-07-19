#!/usr/bin/env bash
# Platform addons — runbooks 04+05, encoded. Runs on the LAPTOP after
# bootstrap.sh. Idempotent.
#
# Secrets come from LOCAL FILES (never git):
#   Cloudflare token: $CF_TOKEN_FILE (default ~/.config/trk-k8s/cloudflare-token)
#   ArgoCD deploy key: ~/.ssh/argocd_trk_k8s
#
# AWS-only parts (EBS CSI) are skipped with --no-aws (on-prem/hetzner).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="$REPO_ROOT/kubeconfig"
CF_TOKEN_FILE="${CF_TOKEN_FILE:-$HOME/.config/trk-k8s/cloudflare-token}"
ARGOCD_KEY="$HOME/.ssh/argocd_trk_k8s"
WITH_AWS=true
[ "${1:-}" = "--no-aws" ] && WITH_AWS=false

helm_i() { # helm_i <release> <ns> <chart> [args...]
  local release="$1" ns="$2" chart="$3"; shift 3
  if helm status "$release" -n "$ns" > /dev/null 2>&1; then
    echo "  $release already installed"
  else
    helm install "$release" "$chart" --namespace "$ns" --create-namespace "$@" > /dev/null
    echo "  $release installed"
  fi
}

echo "### storage: local-path (default StorageClass)"
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.36/deploy/local-path-storage.yaml > /dev/null
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' > /dev/null 2>&1 || true

if $WITH_AWS; then
  echo "### storage: EBS CSI (AWS addon)"
  helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver > /dev/null 2>&1 || true
  helm_i aws-ebs-csi-driver kube-system aws-ebs-csi-driver/aws-ebs-csi-driver
  kubectl apply -f "$REPO_ROOT/cluster/addons/aws-ebs-csi/storageclass.yaml" > /dev/null
fi

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
kubectl apply -f "$REPO_ROOT"/cluster/gitops/*.yaml > /dev/null
echo "  applications applied"

echo
echo "### Platform restored. MANUAL steps that remain after a rebuild:"
echo "  1. Cloudflare: point *.k8s.kahng.dev at the NEW control-plane public IP"
echo "  2. apps/hello/overlays/dev: update the nip.io host, commit + push"
echo "     (argocd serves the old host until the overlay changes in git)"
echo "  3. argocd admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
