# Kubernetes learning cluster — Plan

Goal: build a real multi-node Kubernetes cluster from scratch — machines
provisioned with the **Pulumi Go SDK**, cluster bootstrapped with **kubeadm** —
and document everything learned along the way. The cluster core is
**provider-agnostic**: currently targeting AWS, previously Hetzner (kept), and
deliberately deployable on-prem.

A named end-goal beyond the cluster itself: **running PostgreSQL properly in
Kubernetes** (StatefulSets → PgBouncer → Patroni/ZooKeeper HA → operators),
culminating in a real prebuilt Postgres-backed stack like Saleor or Supabase
(Phase 7).

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

### Phase 2 — kubeadm bootstrap (manual, following a runbook) ✅ 2026-07-14
Executed by hand per `docs/runbooks/02-kubeadm-bootstrap.md`: node prep on all
three, `kubeadm init` on cp-1 (private IP advertise, public-IP cert SAN, pod
CIDR 10.244.0.0/16), workers joined, kubeconfig on the laptop
(`make kubeconfig`). Cluster at v1.35.6, all nodes NotReady awaiting CNI —
the intended end state.

Learning targets hit: what kubeadm actually does (certs, static pods, etcd),
why nodes are NotReady without a CNI, the join token/CA-hash trust model.

### Phase 3 — Cilium ✅ 2026-07-14
Cilium 1.19.4 via Helm (`docs/runbooks/03-cilium.md`, values in
`cluster/addons/cilium/values.yaml` — pod CIDR pinned to 10.244.0.0/16).
All nodes Ready, connectivity test 79/80 (only miss: a log-hygiene check
tripped by a disconnected Hubble UI session). Hubble relay + UI running.
Later lab: kube-proxy replacement.

### Phase 4 — Environment addons (the portable way) — storage ✅ 2026-07-14
- [x] local-path-provisioner as default StorageClass (portable); node-pin
      trade-off demonstrated (`docs/runbooks/04-storage.md`)
- [x] EBS CSI driver as opt-in `ebs-sc` class: node IAM role via Pulumi,
      IMDS hop-limit-3 lesson (debugged with Hubble), cross-node volume
      move demonstrated
- AWS CCM remains a *rebuild lab*, not an install (ADR 003): re-bootstrap
  with `--cloud-provider=external` + AWS CCM, watch `type=LoadBalancer`
  provision an NLB, tear down.
- On-prem equivalents documented alongside: MetalLB, Longhorn.

### Phase 5 — Making it useful ✅ 2026-07-14
All landed (`docs/runbooks/05-platform.md`): metrics-server, ingress-nginx on
fixed NodePorts, cert-manager + Let's Encrypt via DNS-01 on Cloudflare
(kahng.dev; `https://hello.k8s.kahng.dev:30443` with a real cert, firewall
never opened), hello app as Kustomize base+overlay, and ArgoCD syncing it
from the private repo via a read-only deploy key (Synced/Healthy).
Follow-ups: move more addons under ArgoCD; consider app-of-apps pattern.

### Phase 6 — Automate and drill
- Encode the Phase 2 runbook into scripts driven by the inventory contract
  (works against any provider or on-prem machines)
- Teardown → rebuild drill; kubeadm upgrade; etcd backup/restore; node
  replacement
- Stretch: HA control plane; stand the same cluster up on Hetzner again as the
  portability proof

### Phase 7 — Stateful workloads: PostgreSQL (a core learning objective)
Understanding how to deploy and manage Postgres *inside* the cluster — the
hardest and most valuable stateful workload. Comes after the automation phase
on purpose: don't put state you care about on a cluster you can't yet rebuild
confidently. Deliberate progression:
1. Single Postgres instance + PVC — what a StatefulSet actually guarantees
   (stable identity, ordered restarts, storage that follows the pod)
2. **PgBouncer** in front — connection pooling, why Postgres needs it
3. HA with **Patroni** — leader election, automatic failover, and the DCS
   (distributed consensus store) choice: **ZooKeeper**/etcd classically, or
   the Kubernetes API itself when running in-cluster (worth comparing —
   running ZooKeeper explicitly teaches the consensus layer that k8s
   otherwise hides)
4. Operators that package all of the above (CloudNativePG, Zalando's
   postgres-operator — the latter is Patroni underneath) — build by hand
   first, then appreciate what the operator automates
5. Capstone: deploy a real prebuilt Postgres-backed application stack —
   **Saleor** (e-commerce) or **Supabase** — end to end behind ingress
   with TLS

Depends on: storage (Phase 4 CSI/local-path), ingress + cert-manager
(Phase 5), and ideally GitOps (ArgoCD) for the capstone.

## Documentation layout

```
docs/PLAN.md         # this file
docs/decisions/      # ADRs — why choices were made
docs/runbooks/       # repeatable step-by-step procedures
docs/journal/        # dated session logs: what we did, what broke, what we learned
infra/<provider>/    # Pulumi Go programs, one per provider
cluster/             # provider-agnostic cluster layer (contract + bootstrap)
```
