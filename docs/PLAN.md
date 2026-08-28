# Kubernetes learning cluster — Plan

Goal: build a real multi-node Kubernetes cluster from scratch — machines
provisioned with the **Pulumi Go SDK**, cluster bootstrapped with **kubeadm** —
and document everything learned along the way. The cluster core is
**provider-agnostic**: currently Azure (third swap, 2026-08-17, burning
credits that expire Sept 4 — ADR 011), with AWS (ADR 010) and Hetzner
programs kept as reference, and deliberately deployable on-prem. The claim
has now been exercised THREE times — aws→azure, azure→aws, aws→azure —
and `cluster/` was untouched every time.

A named end-goal beyond the cluster itself: **running PostgreSQL properly in
Kubernetes** (StatefulSets → PgBouncer → Patroni/ZooKeeper HA → operators),
culminating in a real prebuilt Postgres-backed stack like Saleor or Supabase
(Phase 7).

## Architecture: two layers, one seam

```
infra/azure/     ── provider-specific ──┐   (current: ADR 011)
infra/aws/       ── provider-specific ──┤   (parked: ADR 010, buckets kept)
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
| Provider (current) | **Azure eastus** — D2als_v7 ×3, ~$0.256/hr, burning credits until Sept 4; foundation rebuilt from zero, deterministic names made the committed config valid again | ADR 011 |
| Provider (parked) | AWS us-east-1 — destroyed 2026-08-17; both S3 buckets (state + backups) kept, pennies idle; return is a resume | ADR 010 |
| Provider (parked) | Hetzner CX23 — no VM capacity July 2026; program kept in `infra/hetzner/` | ADR 001, 002 |
| Portability | Provider-agnostic cluster layer + node inventory contract — exercised on all THREE swaps; `cluster/` never changed | ADR 002, 009, 010, 011 |
| CNI | Cilium | — |
| Bootstrap | Manual kubeadm via SSH first; automate in Phase 6 | — |
| IaC | Pulumi Go SDK | — |
| Pulumi state | azblob `pulumi-state` container in `rg-trk-k8s-persistent` (Key Vault secrets provider); AWS S3 backend parked with its stacks intact | ADR 002, 010, 011 |

Cost: ~$0.256/hr on Azure (D2als_v7 ×3 — no burstable SKU reachable, see
the 2026-08-06 journal), covered by credits until **Sept 4**; the
subscription has NO spending limit, so teardown before expiry is a real
deadline, not a habit. AWS idle cost while parked: pennies of S3.

## Phases

### Phase 0 — Prerequisites ✅ (mostly done)
- [x] Tooling: pulumi, Go, kubectl, hcloud CLI
- [x] Dedicated SSH keypairs, one per provider: `~/.ssh/aws_k8s`,
      `~/.ssh/azure_k8s`, `~/.ssh/hetzner_k8s`
- [x] Azure account hardening + foundation, SCRIPTED this time
      (`infra/azure/foundation.sh`): locked persistent resource group, versioned
      state storage, **Key Vault** secrets provider, service principal,
      registered resource providers — ADR 009
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

### Phase 6 — Automate and drill ✅ 2026-07-15
- [x] Runbooks 02-05 encoded as inventory-driven scripts (`cluster/*.sh`,
      `make bootstrap/platform/rebuild`) — provider-agnostic by contract
- [x] Drill 1: teardown → rebuild, **~8 min** (caught the SSH-readiness race)
- [x] Drill 2: rolling upgrade v1.35.6 → v1.36.2, zero downtime (caught the
      nohup lesson; drove a worker by hand)
- [x] Drill 3: etcd snapshot → destroyed data dir → restore, proven by
      time-travel markers
- [x] Drill 4: unannounced node termination → replacement Ready in ~7 min
      via the same idempotent scripts
- Stretch (parked): HA control plane; Hetzner portability proof; scheduled
  off-node etcd snapshots

### Phase 6.5 — Gateway API migration ✅ 2026-07-18
ingress-nginx retired upstream March 2026 (docs/notes/reverse-proxies.md);
replaced by Cilium's Gateway API implementation — ADR 005.
- [x] Lab A: kube-proxy replaced by Cilium eBPF (required by its Gateway
      API; kubeadm init skips the addon, k8sServiceHost from inventory)
- [x] Lab B: Gateway API v1.4.1 CRDs + `gatewayAPI.enabled` +
      cert-manager gateway-shim
- [x] Gateway `main` (hostNetwork Envoy on the same 30080/30443) with one
      wildcard `*.k8s.kahng.dev` cert; hello Ingress → HTTPRoute; TLS
      moved from app manifests to infra
- [x] ingress-nginx uninstalled; URLs/firewall unchanged through cutover

### Phase 7 — Stateful workloads: PostgreSQL (a core learning objective)
Understanding how to deploy and manage Postgres *inside* the cluster — the
hardest and most valuable stateful workload. Comes after the automation phase
on purpose: don't put state you care about on a cluster you can't yet rebuild
confidently. Deliberate progression:
1. ✅ (2026-07-18) Single Postgres instance + PVC — what a StatefulSet
   actually guarantees (stable identity, ordered restarts, storage that
   follows the pod); drilled: identity + data survive pod deletion,
   local-path pins the pod to the data's node (cordon → Pending)
2. ✅ (2026-07-18) **PgBouncer** in front — connection pooling, why
   Postgres needs it; drilled: 5 clients / pool of 2 / all succeed;
   Deployment-vs-StatefulSet and VIP-vs-headless contrasts
3. ✅ (2026-07-28) HA with **Patroni** — k8s-API DCS + custom image
   (ADR 006); four bootstrap traps journaled (2026-07-26), five drills
   journaled (2026-07-28): switchover, layered-recovery non-event, hard
   failover, rewind-free rejoin, apiserver-fence + the pooler gap.
   Stretch parked: synchronous_mode, real async-loss demo, ZooKeeper
   comparison lab, pooler callbacks
4. ✅ (2026-07-31) Operators — **CloudNativePG 1.30** adopted (ADR 007),
   running alongside the hand-built stack as its control group. Drill
   card replayed: pooler gap closed (3min → 2s), cordon = graceful
   evacuation, promote-on-kill in 2s, and **no fence on a 7-min
   apiserver outage — which disproves ADR 006's premise** (the coupling
   was Patroni's self-promoting leader model, not the k8s-API DCS).
   Plus the capability neither stack had: S3 WAL archiving + PITR,
   restore into a fresh cluster in 52s, RPO measured at one open WAL
   segment. Zalando dropped — the comparison is already made.
5. ✅ (2026-08-27) Capstone: **NetBox** on CNPG, live at
   `https://netbox.k8s.kahng.dev:30443` — 198 tables in a CNPG-managed
   database, RQ worker, native Gateway API route under the wildcard cert
   (`docs/notes/capstone-scope.md`, journal 2026-08-06). Chosen over Saleor
   and Supabase: both Supabase and Immich ship *patched* Postgres images so
   neither would exercise the 7.4 platform, and NetBox's data is this
   cluster's own infrastructure — worth restoring, which is what the Talos
   lab needs. Populated by `apps/netbox/populate.sh` (discovery-driven:
   inventory contract + kubeadm-config + live nodes, never hardcoded).

   **Five-drill card complete (journals 08-18 → 08-27):**
   | drill | result |
   |---|---|
   | 1 failover under load | 31s write gap, 8 failed requests of 124 — the pooler absorbed it; zero rows lost. A graceful pod delete is a *switchover*: the "dead" primary served for 3 more minutes |
   | 2 migrations at scale | Migration was a non-event (applied once, no observable locks). The *delivery machinery* caused a 9-min outage: an unpinned chart secret rotating mid-sync + anti-affinity deadlocking surge rollouts. Both fixed; fixed roll cost 153 failures vs 2,145 |
   | 3 cache vs queue | Both textbook predictions inverted: the queue SURVIVED (AOF on a PVC, ~1s RPO) and the "cache" did NOT degrade gracefully (22s of hard 500s — sessions are load-bearing) |
   | 4 restore with the app | Cascading delete at 23:51:34 → PITR to 23:51:30 in 35s; deleted VM back in the running app, post-target writes correctly absent, restored cluster archiving again |
   | 5 rebuild from git + blob | **8.5 min destroy-to-converged, 1 manual step**, database *born* from the previous generation's archive: populate created nothing but the 3 new public IPs |

   Cross-cutting lesson: infrastructure was rarely the unreliable part.
   Drill 5 needed three attempts and all three failures were in the
   measuring harness, not the cluster.

Depends on: storage (Phase 4 CSI/local-path), ingress + cert-manager
(Phase 5), and ideally GitOps (ArgoCD) for the capstone.

### Open follow-ups (carried, not phases)
- ✅ **Barman Cloud Plugin migration — DONE 2026-08-28** (journal). Plugin
  v0.14.0 installed by platform.sh; destination lives in an ObjectStore CR;
  Cluster keeps a `plugins:` reference. Verified on a live rebuild:
  archiving green, data recovered THROUGH the plugin from an archive the
  in-tree code wrote, and a `method: plugin` base backup completed. The
  1.31 deadline is cleared and operator upgrades are unblocked.
- **Blob/S3 generation sprawl.** `serverName` per rebuild (runbook 06 step
  1b) means dead generations accumulate and no retention policy prunes
  them: currently `pg`, `pg-20260825`, `pg-20260827`, `pg-gen3-20260827`,
  `pg-restore-20260825` in blob, plus the AWS-era prefixes in S3. Pennies,
  but it will keep growing.
- **Stale IPAM records.** Restored data meets rebuilt infrastructure: 9 IP
  records for 3 machines, since public IPs change every rebuild. An IPAM
  hygiene problem the drills exposed but didn't solve.
- **HTML pages are stale** — `architecture.html` and `lessons-learned.html`
  still describe the AWS era; `netbox-drills.html` predates the results.

### Phase 8 — Talos comparison lab (added 2026-07-18)
Rebuild on Talos Linux and judge it against kubeadm+Ubuntu — ADR 004
deferred exactly this until the machinery had been seen; Phases 6/6.5
banked that experience. Two things recorded now, decided then:
- **It is not a provider swap.** The inventory contract carries `sshUser`;
  Talos has no SSH — the whole `cluster/` layer (prep-node, bootstrap,
  etcd drills) gets replaced by machine configs + `talosctl`, and the
  Phase 6.5 stack (kube-proxy-free Cilium, hostNetwork gateway, CRD
  ordering) needs re-porting. `infra/<provider>/` survives unchanged.
- **Deliberately after Phase 7:** the drill that makes Talos interesting
  is rebuild-with-state (machine configs + the etcd/PV backup story with
  real Postgres data at stake) — stateless rebuilds would just re-prove
  Phase 6. Also isolates variables: Postgres lands on a known OS first;
  local-path on Talos's immutable FS (kubelet `extraMounts`) comes second.

## Documentation layout

```
docs/PLAN.md         # this file
docs/decisions/      # ADRs — why choices were made
docs/runbooks/       # repeatable step-by-step procedures
docs/journal/        # dated session logs: what we did, what broke, what we learned
infra/<provider>/    # Pulumi Go programs, one per provider
cluster/             # provider-agnostic cluster layer (contract + bootstrap)
```
