# Kubernetes learning cluster — Plan

Goal: build a real multi-node Kubernetes cluster from scratch — machines
provisioned with the **Pulumi Go SDK**, cluster bootstrapped with **kubeadm** —
and document everything learned along the way. The cluster core is
**provider-agnostic**: currently targeting AWS, previously Hetzner (kept), and
deliberately deployable on-prem.

## Architecture: two layers, one seam

```
infra/aws/       ── provider-specific ──┐
infra/hetzner/   ── provider-specific ──┤──▶  "nodes" inventory contract
(on-prem: hand-written inventory) ──────┘         │
                                                  ▼
cluster/         ── provider-agnostic: kubeadm, Cilium, addons
```

Every infra stack exports the same `nodes` output (name, role, publicIp,
privateIp, sshUser) and the same address plan (10.0.1.10-12 in 10.0.1.0/24).
The `cluster/` layer consumes only that contract — see `cluster/README.md`.
Cloud integrations (CCM, CSI, cloud LBs) are optional per-environment addons;
the core cluster must work without them, or it isn't portable.

## Decisions

| Decision | Choice | Record |
|---|---|---|
| Topology | 1 control plane + 2 workers | — |
| Provider (current) | AWS us-east-1, t3a.medium ×3 (~$0.11/hr for the set) | ADR 002 |
| Provider (parked) | Hetzner CX23 — no VM capacity July 2026; program kept in `infra/hetzner/` | ADR 001, 002 |
| Portability | Provider-agnostic cluster layer + node inventory contract | ADR 002 |
| CNI | Cilium | — |
| Bootstrap | Manual kubeadm via SSH first; automate in Phase 6 | — |
| IaC | Pulumi Go SDK | — |
| Pulumi state | S3 bucket in the AWS account (self-managed backend, passphrase secrets) | ADR 002 |

Cost: ~$82/mo if left running — but billing is per-hour and the new AWS
account has ~$200 of credits, so with `pulumi destroy` between sessions
(~$0.35 per 3-hour lab) the credits should cover the whole project.

## Phases

### Phase 0 — Prerequisites ✅ (mostly done)
- [x] Tooling: pulumi, Go, kubectl, hcloud CLI
- [x] Dedicated SSH keypairs, one per provider: `~/.ssh/aws_k8s`, `~/.ssh/hetzner_k8s`
- [x] Hetzner project "k8s" + API token (parked)
- [x] AWS: IAM Identity Center user (PowerUserAccess) → local profile `personal`
- [x] Account hardening: S3 Block Public Access, default EBS encryption, budget
- [x] S3 state bucket `tkahng-pulumi-state` + `pulumi login` (passphrase file:
      `~/.config/pulumi/trk-k8s.passphrase` — back it up; without it stack
      secrets are unrecoverable)

### Phase 1 — Infrastructure with Pulumi (Go)
- [x] `infra/hetzner/`: network, firewall, placement group, 3× CX23 (parked)
- [x] `infra/aws/`: VPC, public subnet, IGW, security group (SSH/6443 from our
      IP + node-to-node self rule), 3× t3a.medium with fixed private IPs
- [x] `pulumi up` on AWS (stack `dev`); SSH verified to all 3 nodes, private
      network verified between nodes

Learning targets: Pulumi program structure, stacks, config/secrets, outputs —
plus the differences a provider makes (Hetzner firewalls filter only the public
interface; AWS security groups filter everything).

### Phase 2 — kubeadm bootstrap (manual, following a runbook)
On every node: kernel modules + sysctls, containerd (SystemdCgroup), kubeadm/
kubelet/kubectl from pkgs.k8s.io. On the control plane: `kubeadm init`
advertising the **private** IP. Workers: `kubeadm join`. Kubeconfig to laptop.

Learning targets: what kubeadm actually does (certs, static pods, etcd), why
nodes are NotReady without a CNI, the join token/CA-hash trust model.

### Phase 3 — Cilium
Helm install, `cilium status`, connectivity test, Hubble. Later lab:
kube-proxy replacement.

### Phase 4 — Environment addons (the portable way)
- Portable core first: ingress via NodePort, storage via local-path — works on
  any provider including on-prem.
- Then AWS-specific as *optional* addons, clearly marked: AWS CCM
  (`type=LoadBalancer` → NLB), EBS CSI driver.
- On-prem equivalents documented alongside: MetalLB, Longhorn.

### Phase 5 — Making it useful
ingress-nginx, cert-manager + Let's Encrypt, metrics-server, a sample app end
to end.

### Phase 6 — Automate and drill
- Encode the Phase 2 runbook into scripts driven by the inventory contract
  (works against any provider or on-prem machines)
- Teardown → rebuild drill; kubeadm upgrade; etcd backup/restore; node
  replacement
- Stretch: HA control plane; stand the same cluster up on Hetzner again as the
  portability proof

## Documentation layout

```
docs/PLAN.md         # this file
docs/decisions/      # ADRs — why choices were made
docs/runbooks/       # repeatable step-by-step procedures
docs/journal/        # dated session logs: what we did, what broke, what we learned
infra/<provider>/    # Pulumi Go programs, one per provider
cluster/             # provider-agnostic cluster layer (contract + bootstrap)
```
