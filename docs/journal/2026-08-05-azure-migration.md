# 2026-08-05 — AWS to Azure in one session, and the seam finally tested

Access to the AWS account was lost. That took the Pulumi state backend, the
Postgres backup bucket built five days earlier, and any use for the AWS SSH
key. A new Azure subscription with $200 of trial credit replaced it — and
the forced migration turned into the experiment ADR 002 had been promising
since July 13.

**Result: `make bootstrap` brought up Kubernetes v1.36.3 on Azure on the
first attempt with ZERO changes inside `cluster/`.** By the end of the
session `https://hello.k8s.kahng.dev:30443` returned 200 from an Azure VM
with a verified Let's Encrypt wildcard cert.

## The portability verdict

Changed: the Makefile header (`INFRA_DIR`, `SSH_KEY`, a `PULUMI` wrapper)
and a new `infra/azure/`. Unchanged: `prep-node.sh`, `bootstrap.sh`, every
Cilium/gateway/cert-manager value, all of `apps/`, all of
`cluster/gitops/`.

Three earlier decisions earned that, and it is worth naming which:

1. **The contract carries `sshUser` as DATA, not an assumption.** Azure's
   `adminUsername` is configurable (it rejects `admin`/`root`/`user`/`test`
   but not `ubuntu`), so a field that looked like pedantry on day one cost
   exactly nothing.
2. **The address plan was pinned identically** (10.0.1.10-12), so Cilium's
   `k8sServiceHost` and every runbook needed no thought.
3. **ADR 003 refused to install a cloud-controller-manager.** The thing
   deliberately NOT built is what made the swap free — there was no cloud
   integration to port. Three weeks of resisting the convenient option paid
   in one afternoon.

The ONE honest seam inside the cluster layer was storage: `platform.sh`'s
`WITH_AWS` boolean became `--provider=aws|azure|none`, and the EBS CSI
addon gained an Azure Disk CSI counterpart (`managed-csi`,
`disk.csi.azure.com`). It installed cleanly and needed no cloud-config
plumbing — the node's user-assigned managed identity over IMDS is enough,
exactly parallel to EBS CSI riding the instance profile.

## Capacity: the Phase 1 lesson, occurrences three and four

Two hard walls, same root cause, both invisible until deploy time.

**The entire B-series is capacity-restricted on a trial subscription.**
`Standard_B2als_v2` was a perfect match — burstable, 2 vCPU/4 GiB, and
$0.0376/hr, *identical to t3a.medium in both shape and price*. It fails:

    409 SkuNotAvailable "Following SKUs have failed for Capacity
    Restrictions: Standard_B2als_v2"

**And `az vm list-sizes` lies.** It reports B2als_v2 as available in
eastus. Only `az vm list-skus`'s `restrictions` field tells the truth: of
**522** SKUs visible in eastus, just **16** two-vCPU sizes are actually
unrestricted, all newer D/F v7 families.

**Then: Total Regional vCPUs quota is 4.** Three 2-core nodes need 6:

    409 OperationNotAllowed "exceeding approved Total Regional Cores
    quota. Current Limit: 4, Current Usage: 4, Additional Required: 2"

Checked eastus, westus2, centralus, eastus2 — **all 4**, so relocating
does not help. This is a subscription-wide trial cap, not a regional
accident.

"A provider listing a product is not the same as having capacity FOR YOU"
has now been true on every cloud this project has touched: Hetzner had no
CX23s (July 13), AWS held a new account's third instance for
`PendingVerification` (also July 13), and Azure gates a whole VM family
behind trial quota *and* caps total cores.

**The fix introduced something the AWS program never had: per-role VM
sizing.** Control plane `Standard_D2als_v7` (2 vCPU — kubeadm's NumCPU
preflight *requires* 2); workers `Standard_F1as_v7` (1 vCPU). Every node
still 4 GiB, exactly 4 cores total, and every drill needing two workers
still works. Arguably closer to real practice than three identical nodes.

Sequencing gotcha: sitting at exactly 4/4 cores, shrinking a worker and
creating another in one `pulumi up` deadlocks — Pulumi may attempt the
create before the resize frees a core. Targeted destroy first
(`--target urn:...VirtualMachine::k8s-worker-1`), then `up`.

## What Azure does differently

- **A VM is three resources**: `PublicIPAddress` + `NetworkInterface` +
  `VirtualMachine`. Nine resources where AWS had three. Azure exposes the
  plumbing AWS hides.
- **Resource groups**, with no AWS equivalent — and they make ADR 008's
  lifecycle boundary a first-class object rather than a convention. On AWS
  that boundary needed a second Pulumi stack plus a `StackReference`; here
  it's two resource groups, one carrying a `CanNotDelete` lock the
  platform itself enforces.
- **NSG rules need numeric priorities** (100-4096) and there is no
  self-referencing rule — because Azure's built-in `AllowVnetInBound`
  (priority 65000) already permits all intra-VNet traffic, so etcd,
  kubelet and VXLAN work with **nothing declared**. Third distinct answer
  to the same question: Hetzner filtered only the public NIC, AWS denied
  everything including internal, Azure allows internal by default.
- **No internet gateway or route table.** A public IP grants egress
  (default outbound access was retired Sept 2025), so the IPs needed for
  SSH do double duty.
- **Resource providers are unregistered on a fresh subscription.**
  Creating an unregistered type fails with an error that reads like a
  permissions problem. `foundation.sh` registers Storage, KeyVault,
  Compute, Network and ManagedIdentity up front and waits for them.
- **The typed SDK caught three enum-name mistakes at compile time**
  (`IPAllocationMethodStatic` not `Ip…`,
  `DiskStorageAccountTypes_StandardSSD_LRS` not `StorageAccountTypes…`).
  Worth folding into `docs/notes/pulumi-vs-yaml.md`: with YAML these would
  have been deploy-time failures.

## New-account hardening, Azure edition

The Azure counterpart to July 13's AWS hardening, now a SCRIPT
(`infra/azure/foundation.sh`) rather than a journal entry — because the
AWS state bucket was hand-made and documented only in prose, and that
knowledge evaporated with the account.

- **Spending limit is ON by default on a free trial**, and it *disables
  resources* rather than charging the card when credits run out. Strictly
  better protection than anything AWS offered. Azure repeatedly invites
  you to remove it; don't.
- **Credits expire 30 days from signup, not when spent.** The clock is the
  binding constraint, not the money — the opposite of AWS's leisurely
  6-month credits.
- **Budgets only notify.** The spending limit is what actually stops
  spending. (Same lesson as the AWS "$1 zero-spend budget", learned again.)
- **Security Defaults** (free) enforces MFA tenant-wide. Not readable or
  settable from `az` without a Graph permission grant — portal only.
- **A personal Microsoft account as tenant owner is the AWS-root
  equivalent.** Unlike AWS, splitting out a separate admin user buys
  almost nothing here: without Entra ID **P2** (PIM, Conditional Access)
  the two identities would have identical powers. The separation that DOES
  matter is human-vs-automation, and that one is real.
- **Service principal needs Contributor AND "Role Based Access Control
  Administrator".** Contributor cannot create role assignments, which the
  node managed identity requires. Both still narrower than Owner.
- **Shared-key access must stay ENABLED** on the state storage account:
  Pulumi's `azblob` backend authenticates with an account key. Hardened
  everything else (no public blob access, TLS 1.2 floor, HTTPS only) plus
  versioning and 30-day soft delete, because state corruption is
  recoverable and state deletion is not.
- **Key Vault replaces the passphrase file** as the secrets provider. The
  AWS setup warned that losing `trk-k8s.passphrase` made stack secrets
  unrecoverable; recoverability now lives in the cloud. The
  `encryptedkey` in `Pulumi.dev.yaml` is safe to commit — it is the data
  key encrypted *by* the vault key, useless without vault access.
- **Purge protection left OFF deliberately**: a soft-deleted vault name is
  blocked for 90 days, a nasty trap in a lab you may rebuild.

## Cost

~$0.232/hr all in (3 VMs + 3 Standard static public IPs at $0.005/hr each)
versus AWS's ~$0.135/hr, because the burstable family is unavailable. A
3-hour lab is ~$0.70. Leaving it up for a month would consume essentially
the whole $200 credit.

**Teardown changed character**: on AWS forgetting `make destroy` was
untidy; here it is most of the budget.

## Operational notes

- **"No route to host" between ArgoCD's controller and repo-server was
  transient** — the repo-server was still starting. Drill 2's lesson for
  the fourth time: not every error is real, some are just *too early*.
  Cilium was healthy throughout (`cilium-dbg node list` showed all three
  nodes and correct CIDRs), which is what ruled out a real overlay
  problem on an unfamiliar cloud.
- **App-of-apps (ADR 008) had its first real use** and worked: platform.sh
  applied only `root.yaml`, and the four children came from git.
- **All three local secret files survived** — Cloudflare token, postgres
  password, ArgoCD deploy key — because none were ever AWS-dependent. The
  file-driven secrets discipline from Phase 5 meant TLS and GitOps came
  back untouched.
- **The wildcard cert issued in ~2.5 minutes via DNS-01**, before the
  Cloudflare A record was even updated — DNS-01 needs no inbound, so it
  cannot care which cloud the cluster is on.

## What is now broken or deferred

- **Postgres backups are OFF.** `barmanObjectStore` pointed at
  `s3://trk-k8s-pg-backups` with `inheritFromIAMRole`; the bucket and the
  account are gone. CNPG supports `azureCredentials` with
  `inheritFromAzureAD`, and `infra/azure` already creates the
  `id-trk-k8s-node` identity for precisely this — the port needs a blob
  container, a Storage Blob Data Contributor assignment, and an
  `https://<account>.blob.core.windows.net/<container>` path. Its own lab,
  exactly as it was on AWS.
- **All 7.4 backup data is gone.** The measured result (RPO = one open WAL
  segment, 52s restore) stands as a finding; the bytes do not.
- **`infra/aws/` and `infra/aws-persistent/` are dead reference** — they
  describe an account nobody can reach. Kept, like `infra/hetzner/`,
  because deleting them would erase the comparison that makes the Azure
  program legible.
- **Workers are 1 vCPU.** CNPG plus a capstone app will be slower than on
  AWS. A vCPU quota increase request is free and would allow uniform
  2-core nodes; trial subscriptions are sometimes refused.

## State

3 nodes Ready (v1.36.3) on Azure, Cilium eBPF kube-proxy-free, Gateway API
edge serving verified TLS, both StorageClasses present (`local-path`
default + `managed-csi`), ArgoCD app-of-apps converging, hello app live.
Phase 7.5 (NetBox capstone) resumes from here — on a different cloud, with
the portability claim proven rather than assumed.
