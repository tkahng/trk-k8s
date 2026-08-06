# 2026-08-06 — Three layers of Azure quota, and backups rebuilt on blob

Two jobs today: get the machines to match the AWS baseline (so drill timings
stay comparable), and rebuild the backup capability the lost AWS account took
with it. Both done. The quota archaeology on the way is the more transferable
finding.

## Azure gates compute at THREE independent layers

This took three separate failures to map, and no single command answers
"can I actually create this VM".

| Layer | What it is | Where to look |
|---|---|---|
| 1 | **Total Regional vCPUs** — subscription-wide, per region | `az vm list-usage` |
| 2 | **Per-FAMILY vCPUs** — a separate counter per VM family | `az vm list-usage` |
| 3 | **SKU availability/capacity** in that region | `az vm list-skus` `restrictions` |

All three must pass. `az vm list-sizes` sees **none** of them — it reported
`Standard_B2als_v2` as available in a region where every layer blocked it.

### The three walls, in order

1. **Free trial capped Total Regional vCPUs at 4** (identical in eastus,
   westus2, centralus, eastus2 — so relocating never helps a layer-1
   problem). Three 2-core nodes need 6. Forced a per-role sizing workaround:
   2-core control plane (kubeadm's NumCPU preflight requires 2) + two 1-core
   workers.
2. **The quota-increase request was DENIED.** Trial subscriptions generally
   are. Upgrading to **pay-as-you-go** lifted layer 1 from 4 → **10** per
   region immediately.
3. **Then westus2 looked like the answer and wasn't.** `B2als_v2` is
   capacity-restricted in eastus but *listed* in westus2 — layer 3 passes
   there. It still failed:
   `409 exceeding approved standardBasv2Family Cores quota. Current Limit: 0`.
   Layer 2. And the trap: **`Standard BS Family vCPUs` reads 10**, which is
   B-series **v1** — an entirely different counter from `standardBasv2Family`.

### The bit that surprised me

Chasing layer 2, I checked whether the B-series v1 SKUs with quota 10 were
usable. **`Standard_B2s` and `Standard_B2ms` are not offered in either
region at all.** So a family quota can exist for SKUs that no longer ship —
quota and catalogue are separate systems, and neither implies the other.

Conclusion: **no burstable SKU is reachable on this subscription.** That's
not a search problem, it's the shape of the offering.

### Settled configuration

Uniform `Standard_D2als_v7` × 3 in **eastus** — 2 vCPU / 4 GiB each,
matching the AWS `t3a.medium` shape so drill numbers stay comparable to the
baseline. Dalsv7 family quota 10, unrestricted, proven deployed.
**~$0.256/hr all in vs AWS's ~$0.135/hr** — roughly 1.9× for identical
specs, purely because the cheap burstable tier is out of reach.

Per-role sizing is gone; it was a workaround for a constraint that no longer
exists. eastus keeps the cluster colocated with `rg-trk-k8s-persistent`.

### The safety cost of upgrading, stated plainly

Pay-as-you-go **removes the spending limit** that previously made overspend
*physically impossible*. Budget alerts only notify. `make destroy` is now the
only thing between a forgotten cluster and a real bill. Same discipline,
uncapped consequence.

## Backups, ported to Azure Blob

The 7.4 capability rebuilt. What it took:

- **Container `pg-backups`** in `rg-trk-k8s-persistent`, added to
  `foundation.sh` alongside the state container — same account, same
  lifecycle, both must outlive every cluster.
- **Role assignment** in `infra/azure`: the node's user-assigned identity
  (`id-trk-k8s-node`) gets **Storage Blob Data Contributor** scoped to the
  **container**, not the storage account — the same account holds Pulumi
  state and the nodes have no business there. *Tighter than the AWS version*,
  which granted bucket-level access.
- **`PrincipalType: ServicePrincipal` is required** on the RoleAssignment for
  managed identities, or it races Entra replication and fails
  `PrincipalNotFound`.
- **CNPG**: `barmanObjectStore.destinationPath` →
  `https://<account>.blob.core.windows.net/pg-backups`, credentials via
  `azureCredentials.inheritFromAzureAD: true`. No credential Secret anywhere.

### `inheritFromAzureAD` works on self-managed kubeadm

This was the genuine unknown. On AKS, managed identity is wired into the pod
runtime; here barman has to reach IMDS directly from a pod — the exact path
that needed the **hop-limit-3** fix on AWS. Azure has no equivalent wrinkle
and needed no cloud-config plumbing. A pleasing asymmetry: the harder cloud
for quota is the easier one for pod-to-metadata identity.

### The counter agreed with reality this time

    archived_count=5  failed_count=0     5 objects in the container

On AWS these disagreed catastrophically — the counter reached 15 against an
**empty** bucket, because CNPG's archive command exits 0 with no destination
configured. Printing both side by side is now the habit, and it's the check
worth keeping *especially* now that it passes: a green counter is exactly
what a silent failure looks like.

CNPG bootstrap: **84s** to 2 healthy instances, against 78s on AWS — the
payoff of getting back to 2-vCPU nodes.

## Restore drill: RPO reproduced on a second cloud

Same three-marker design as 7.4, because it measures the recovery *point*
rather than just "did data come back":

| Marker | Where it lived | Result |
|---|---|---|
| A — before the base backup | inside the base backup | **survived** |
| B — after backup, WAL `…006` archived | replayed from blob | **survived** |
| C — after that, WAL `…007` never archived | nowhere in blob | **lost** |

    original:  3 rows   marker C present
    restored:  2 rows   marker C absent

**RPO = the currently-open WAL segment**, now verified on two providers with
independent tooling. Restored into `pg-restored`, a cluster that did not exist
when the backup was taken.

Capstone drills 4 and 5 are unblocked.

## Two improvements over the AWS original

Both are direct consequences of losing that account and rebuilding with it
fresh in mind:

1. **Container-scoped credentials** instead of bucket-scoped — the nodes
   cannot reach the Pulumi state in the same storage account.
2. **A platform-enforced `CanNotDelete` lock** on the persistent resource
   group instead of my own `ForceDestroy: false` convention. Azure refuses
   the delete; it doesn't depend on me having configured it correctly.

Unchanged trade-off (ADR 007): identity is **node-scoped**, so any pod on the
node could reach the container. Workload Identity would scope per
ServiceAccount but needs an OIDC issuer kubeadm doesn't publish.

## State

3 nodes Ready (v1.36.3, uniform 2 vCPU/4 GiB), all five ArgoCD apps
Synced/Healthy, WAL archiving live to blob, 6-hourly ScheduledBackup active,
restore proven. Phase 7.5 (NetBox capstone) is next with its full drill card
available — nothing blocked.
