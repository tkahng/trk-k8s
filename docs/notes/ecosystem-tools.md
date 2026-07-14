# Ecosystem tools, sorted by layer

Encountered: KubeVela, Crossplane, ArgoCD, Talos, OAM, Kustomize, Helm.
They live at different layers of the stack:

| Layer | Question | Tool | Relation to this project |
|---|---|---|---|
| OS | What runs on the machines? | **Talos** | Alternative to our Ubuntu + kubeadm Phase 2 — immutable, API-only OS (no SSH/shell) purpose-built for k8s. Hides exactly what we're trying to learn; good post-Phase-6 comparison lab |
| Infra provisioning | Who creates cloud resources? | **Crossplane** | Alternative to our Pulumi layer that runs *inside* a cluster: cloud resources as k8s custom resources. Chicken-and-egg (needs a first cluster). Awareness only |
| Cluster bootstrap | How do machines become a cluster? | *(our kubeadm)* | The thing we're learning |
| App packaging | How do I write/reuse manifests? | **Helm** | Package manager: charts = YAML templates + values. We meet it in Phase 3 (Cilium installs via Helm chart) |
| | | **Kustomize** | Template-free base + overlay patching for our *own* YAML; built into kubectl (`-k`). Rule of thumb: Helm for third-party, Kustomize for your own |
| Delivery | How do manifests reach the cluster? | **ArgoCD** | GitOps controller: cluster continuously reconciles to a git repo; no more kubectl-apply-from-laptop. Adopted into Phase 5/6 — also strengthens portability (the cluster's contents become a repo pointable at any cluster) |
| Dev abstraction | How do devs avoid YAML entirely? | **OAM** (spec) + **KubeVela** (impl) | Platform-engineering layer: abstract app descriptions (components/traits) rendered by a platform team's definitions. Skippable for learning k8s itself |

Composition note: these stack rather than compete — e.g. ArgoCD deploys
things described by Helm charts or Kustomize overlays, onto a cluster that
Talos or kubeadm bootstrapped, on machines Pulumi or Crossplane provisioned.
