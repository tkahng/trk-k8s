# Could Pulumi's Kubernetes provider replace the YAML?

Technically almost all of it: typed k8s resources in Go, `helm.Release`,
`crd2pulumi` for CRs. One `pulumi up` could produce everything.

## Why we don't: one reconciler per object

Pulumi and ArgoCD are both reconciliation engines — push-with-state-file
vs pull-from-git-continuously. Pointed at the same objects they fight
(Pulumi applies → selfHeal reverts → Pulumi sees drift → forever). Every
object gets exactly one owner. Our boundary:

| Layer | Owner | Language | Why |
|---|---|---|---|
| Cloud (machines, VPC, IAM) | Pulumi | Go | Real language earns its keep at cloud APIs |
| Bootstrap (kubeadm) | bash over SSH | — | Portability seam (ADR 002); no reconciler should own it |
| In-cluster (addons, apps) | ArgoCD | YAML/Kustomize/Helm in git | YAML is this layer's native tongue: kubectl explain, all docs, ArgoCD diffs, overlay model |

## Known refinements

- The actual gap is `platform.sh` imperatively helm-installing addons.
  Fix = app-of-apps: addons become ArgoCD Applications; platform.sh
  shrinks to "install ArgoCD, apply one Application". (Planned.)
- Hybrid exists: Pulumi `renderYamlToDirectory` — author in Go, emit YAML
  into git for ArgoCD. Type-checked authoring + GitOps delivery, at the
  cost of a build step between you and your manifests. Revisit if YAML
  volume gets painful (capstone?).
- All-Pulumi (no ArgoCD) is a legitimate industry pattern; rejected here
  because the GitOps model already proved itself (Drill 1: self-restoring
  cluster) and Phase 7's ecosystem (operators, Patroni) is YAML-shaped.
