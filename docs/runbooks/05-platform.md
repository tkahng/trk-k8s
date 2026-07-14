# Runbook 05 — Platform: metrics, ingress, TLS, GitOps

Phase 5, all from the laptop. Ends with the hello app serving HTTPS at a
real domain and deploying itself from git.

## metrics-server

`helm install metrics-server` with `--kubelet-insecure-tls`
(`cluster/addons/metrics-server/values.yaml` — kubeadm kubelets serve
self-signed certs; the flag is the standard learning-cluster tradeoff).
Enables `kubectl top` and, later, HPAs.

## ingress-nginx — the portable no-cloud-LB path

NodePort with FIXED ports 30080/30443
(`cluster/addons/ingress-nginx/values.yaml`), opened in the AWS security
group from the admin IP only (infra/aws). Set as the default IngressClass.
The same Ingress resources would work unchanged behind MetalLB (on-prem) or
a cloud LB (with CCM) — only this values file changes.

## TLS — cert-manager + Let's Encrypt DNS-01 (Cloudflare)

- ClusterIssuers: `cluster/addons/cert-manager/issuers/letsencrypt.yaml`
  (staging + prod). DNS-01 validates by writing a TXT record, so **no
  inbound access is needed** — the firewall stays closed, port 80 never
  opens. This is why DNS-01 > HTTP-01 for locked-down clusters.
- Cloudflare API token (zone-scoped) lives ONLY in the
  `cloudflare-api-token` secret in the cert-manager namespace. Created
  manually from a terminal; never in git; roll it if ever exposed
  (Cloudflare tokens scope to whole zones — that's why this cluster got a
  dedicated low-stakes domain, kahng.dev, not a heavily-used zone).
- DNS: wildcard A record `*.k8s.kahng.dev` → control-plane public IP,
  Cloudflare proxy OFF. Changes every rebuild — update in Cloudflare.
- Consumption is one annotation + tls block on an Ingress (see
  `apps/hello/overlays/dev/ingress-host.yaml`); cert-manager materializes
  the Certificate automatically. Issued in ~90s.
- Verify: `curl -v https://hello.k8s.kahng.dev:30443/` → issuer
  "Let's Encrypt", verify ok.

## GitOps — ArgoCD

- Install: plain `helm install argocd argo/argo-cd -n argocd`.
- Repo access: dedicated read-only **deploy key** (`~/.ssh/argocd_trk_k8s`,
  public half on the GitHub repo) in a secret labeled
  `argocd.argoproj.io/secret-type: repository`. No PATs, no account-wide
  access. GitHub note: a given SSH key can exist once across ALL of GitHub
  ("Key is already in use" usually means your add already worked).
- Applications live in `cluster/gitops/` (e.g. `hello-app.yaml`): source =
  this repo, path = a kustomize overlay, `automated` sync with prune +
  selfHeal.
- UI: `kubectl -n argocd port-forward svc/argocd-server 8080:443`,
  user `admin`, password:
  `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`

**The workflow change this creates:** apps under ArgoCD are no longer
`kubectl apply`'d from laptops. Edit manifests → push → ArgoCD reconciles.
Manual drift gets reverted (selfHeal); deletions in git get pruned.
