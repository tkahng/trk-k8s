# ADR 009 — Migrate to Azure; the provider seam, finally tested

Date: 2026-08-05. Status: accepted, machines + cluster layer implemented.

## Context

Access to the AWS account was lost. That took with it the Pulumi state
backend (`s3://tkahng-pulumi-state`), the Postgres backup bucket built
five days earlier under ADR 008, and the `~/.ssh/aws_k8s` keypair's
usefulness. A new Azure subscription with $200 of trial credit replaced
it.

This is also the first real test of ADR 002's central claim: that
`infra/<provider>/` is swappable because everything downstream consumes
only the `nodes` inventory contract. Hetzner was written and never
deployed; AWS ran for three weeks. Nothing had ever proved the seam.

## Decision

**Azure is the provider.** `infra/azure/` (azure-native SDK v3, stack
`dev`) provisions 1 control plane + 2 workers on the same 10.0.1.10-12
address plan and exports the same `nodes` contract. `infra/aws/` and
`infra/aws-persistent/` stay in the repo as dead reference — they
describe an account nobody can reach, and deleting them would erase the
comparison that makes the Azure program legible.

**The foundation is a script, not a journal entry.** `infra/azure/
foundation.sh` creates everything Pulumi cannot create for itself:
`rg-trk-k8s-persistent` (locked `CanNotDelete`), a hardened storage
account + container for state (versioned, 30-day soft delete), a Key
Vault + RSA key as the secrets provider, the `sp-trk-k8s-pulumi` service
principal, and the SSH keypair. On AWS the equivalent bucket was made by
hand and documented only in a journal entry — precisely the knowledge
that evaporates, as this migration proved.

**Secrets provider is Azure Key Vault, not a passphrase file.** The AWS
setup warned that losing `~/.config/pulumi/trk-k8s.passphrase` made stack
secrets unrecoverable. Recoverability now lives in the cloud.

**Pulumi runs as a service principal**, never as the human. `infra/azure/
pulumi.sh` wraps every invocation with the SP credentials and a live
storage-key lookup, because a ritual that must be remembered is a ritual
that gets skipped.

**ADR 008's lifecycle boundary is now native.** Azure resource groups
model it directly: `rg-trk-k8s-dev` is disposable, `rg-trk-k8s-persistent`
carries a platform-enforced delete lock. No second Pulumi stack and no
`StackReference` needed — the boundary is an object, not a convention.

## The seam held

`make bootstrap` brought up Kubernetes v1.36.3 — node prep, `kubeadm
init`, both joins, the Step 4.5 stability gate, Gateway API CRDs, Cilium
with eBPF kube-proxy replacement, all three nodes Ready — **on the first
attempt, with zero changes inside `cluster/`.**

Changed: the Makefile header (`INFRA_DIR`, `SSH_KEY`, `PULUMI` wrapper)
and a new `infra/azure/`. That is all.

Three earlier decisions earned this, and it is worth naming which:

1. **The contract carries `sshUser` as DATA.** Azure's `adminUsername` is
   configurable (it rejects `admin`, `root`, `user`, `test`… but not
   `ubuntu`), so a field that looked like pedantry on day one cost
   nothing here.
2. **The address plan was pinned identically**, so Cilium's
   `k8sServiceHost` and every runbook needed no thought.
3. **ADR 003 refused to install a cloud-controller-manager.** The thing
   deliberately NOT built is what made the swap free — there was no cloud
   integration to port.

## What Azure does differently (recorded in main.go)

- **A VM is three resources**: `PublicIPAddress` + `NetworkInterface` +
  `VirtualMachine`. AWS bundles all of it into `NewInstance`; nine
  resources where AWS had three.
- **NSG rules need numeric priorities** and there is no self-referencing
  rule — Azure's built-in `AllowVnetInBound` already permits all
  intra-VNet traffic, so etcd/kubelet/VXLAN work with **nothing
  declared**. The third distinct answer to the same question: Hetzner
  filtered only the public NIC, AWS denied everything including
  internal, Azure allows internal by default. Exactly the class of
  difference ADR 002 said the seam existed to absorb.
- **No internet gateway or route table.** A public IP grants egress
  (default outbound access is retired), so the IPs needed for SSH do
  double duty.
- **Resource providers are unregistered on a fresh subscription.**
  Creating an unregistered type fails with an error that reads like a
  permissions problem. `foundation.sh` registers Storage, KeyVault,
  Compute, Network and ManagedIdentity up front.

## Capacity: the Phase 1 lesson, third and fourth occurrence

Sizing here is quota-shaped, not preference-shaped:

1. **The entire B-series is capacity-restricted.**
   `Standard_B2als_v2` was a perfect match — burstable, 2 vCPU/4 GiB,
   $0.0376/hr, identical to `t3a.medium` in both shape and price. It
   fails `409 SkuNotAvailable`. `az vm list-sizes` reports it available;
   only `az vm list-skus`'s `restrictions` field tells the truth. Of 522
   SKUs visible in eastus, **16** two-vCPU sizes are usable.
2. **Total Regional vCPUs is capped at 4** — verified identical in
   eastus, westus2, centralus and eastus2, so relocating does not help.
   Three 2-core nodes need 6.

Resolution, preserving the topology inside 4 cores: **per-role sizing**
(new — AWS used one size for all three). Control plane
`Standard_D2als_v7` (2 vCPU, kubeadm's NumCPU preflight requires 2);
workers `Standard_F1as_v7` (1 vCPU), every node still 4 GiB. Every drill
needing two workers still works.

"A provider listing a product is not the same as having capacity FOR
YOU" has now been true on all three clouds: Hetzner had no CX23s, AWS
held a new account's third instance for `PendingVerification`, Azure
gates a VM family behind trial quota *and* caps total cores.

## Consequences

- **Cost ~$0.232/hr all in vs AWS's ~$0.135/hr** (non-burstable VMs,
  plus 3 Standard static public IPs at $0.005/hr). A 3-hour lab is
  ~$0.70. Leaving it up for a month would consume essentially the whole
  $200 credit — and **credits expire 30 days from signup regardless of
  use**. Teardown is now budget discipline, not tidiness.
- Worker nodes have **1 vCPU**. The etcd stalls that plagued 2-vCPU AWS
  nodes were control-plane-side, which keeps 2 — but CNPG plus a capstone
  app on a 1-core worker will be slow. Bump if a quota increase is
  granted.
- **`platform.sh` needs an Azure branch**: its `WITH_AWS` flag installs
  the EBS CSI driver and `ebs-sc` StorageClass. Azure Disk CSI is the
  counterpart. This is the one genuine provider seam inside the cluster
  layer.
- **`apps/postgres-cnpg/base/cluster.yaml` is broken on Azure** — it
  points `barmanObjectStore` at `s3://trk-k8s-pg-backups` with
  `inheritFromIAMRole`. CNPG supports `azureCredentials` with
  `inheritFromAzureAD`; the node identity (`id-trk-k8s-node`) exists for
  exactly this and still needs its role assignment.
- **All Postgres backups from 7.4 are gone** with the AWS account. The
  RPO measurement (one open WAL segment) stands as a recorded result;
  the data does not.
- `make persist-up` / `persist-destroy` are replaced by `make foundation`.
- Phase 8's Talos comparison is now a *second* portability axis rather
  than the first: Azure tested provider portability, Talos tests OS
  portability (no SSH, so `cluster/` genuinely gets replaced).

## Addendum, 2026-08-06 — pay-as-you-go, and westus2

The free-trial quota-increase request was **denied** (trial subscriptions
generally are). Upgrading to **pay-as-you-go** lifted Total Regional vCPUs
from 4 to **10** per region immediately, which retired the per-role sizing
workaround.

But the B-series stayed restricted in **eastus** even after the upgrade —
so the two failures that both reported "capacity" had *different causes*:

| Failure | Real cause | Remedy |
|---|---|---|
| 4-vCPU regional cap | subscription **entitlement** | upgrade billing |
| B-series `SkuNotAvailable` in eastus | genuine **regional capacity** | move region |

Worth separating, because the remedies have nothing in common. `az vm
list-skus` reports both identically.

**Decisions:** cluster moves to **westus2**, where `Standard_B2als_v2` is
unrestricted with a 10-core quota — 3 nodes of 2 vCPU / 4 GiB at
$0.0376/hr each, **~$0.128/hr all in, marginally cheaper than AWS's
~$0.135/hr** and the same machine shape the project ran on for three
weeks. Drill timings are comparable to the AWS baseline again, which
matters more than the money: the whole method is comparative.

The persistent resource group (Pulumi state + Key Vault) **stays in
eastus**. That split is deliberate — state and backups in a different
region from the cluster they describe is what you want when the cluster's
region is what fails.

**The safety cost of upgrading, recorded plainly:** pay-as-you-go removes
the spending limit that previously made overspend *physically impossible*.
Budget alerts only notify. `make destroy` is now the only thing between a
forgotten cluster and a real bill — the discipline is unchanged, but the
consequence of skipping it is no longer capped.
