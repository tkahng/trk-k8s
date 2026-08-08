# ADR 010 — Return to AWS; Azure decommissioned to zero

Date: 2026-08-06. Status: accepted, implemented.

## Context

The AWS account whose loss forced the Azure migration (ADR 009) was
restored. Azure — on pay-as-you-go with **no spending limit** since the
quota saga — bills real money for anything left behind, so the exit had to
be total. The Azure detour lasted two days end to end and produced ADR 009,
its two addenda, and the three-layer quota model.

## What the suspension actually did (the load-bearing discovery)

**A suspended AWS account keeps its resources.** On regaining access:

- `s3://tkahng-pulumi-state` — the Pulumi backend, intact, both stacks
  present (`trk-k8s-aws/dev` at 0 resources, cleanly destroyed before the
  suspension; `trk-k8s-aws-persistent/prod` with all its resources)
- `s3://trk-k8s-pg-backups` — **9 backup objects**, including base backups
  the 6-hourly ScheduledBackup kept writing right up to the suspension
- The IAM policy, both stacks' config, the local passphrase file and
  `~/.ssh/aws_k8s` — all valid
- `pulumi preview` on the persistent stack: **unchanged**; on dev:
  a clean 15-to-create

So the return is a *resume*, not a rebuild: ADR 008's lifecycle boundary
held across account suspension — a failure mode nobody designed for,
harsher than any drill. The backups outlived the account's own
accessibility.

Contrast worth recording: the AWS "loss" was recoverable because
suspension preserves state. The Azure exit is NOT recoverable — we deleted
everything deliberately, including the state backend and Key Vault,
because an idle pay-as-you-go subscription with a locked resource group
still bills for storage and would do so forever.

## The teardown (Azure → literally zero)

Order mattered: the Pulumi state describing the cluster lived inside the
storage account being deleted, so the cluster RG had to go first (it was
already gone — the last `make destroy` had completed).

1. `CanNotDelete` lock removed from `rg-trk-k8s-persistent`
2. `rg-trk-k8s-persistent` deleted (state container, backup container,
   Key Vault, node managed identity)
3. Key Vault **purged** from soft-delete (7-day retention would otherwise
   hold the name; soft-deleted vaults don't bill, but zero means zero)
4. `NetworkWatcherRG` deleted (auto-created by Azure on first VNet;
   needed a second attempt)
5. Service principal `sp-trk-k8s-pulumi` deleted (app + SP)
6. Two **orphaned role assignments** cleaned — assignments survive their
   principal's deletion as unresolvable entries; find them with
   `az role assignment list --query "[?principalName=='']"`
7. Local credential files removed (`azure-sp.env`, `azure-foundation.env`)

Final state: 0 resource groups, 0 resources, no soft-deleted vaults.
The subscription bills nothing and will bill nothing.

## The return (repo changes)

- Makefile restored to the AWS header (INFRA_DIR, SSH_KEY, AWS_PROFILE,
  passphrase-file PULUMI, `persist-*` targets, `aws sso login`), keeping
  the explicit `--provider=aws` on the platform target
- `platform.sh` default provider back to `aws`; the `azure` branch remains
- CNPG `barmanObjectStore` back to `s3://trk-k8s-pg-backups` with
  `inheritFromIAMRole`, keeping everything added during the Azure era
  (managed `netbox` role, `Database` CR, netbox credentials flow)
- `infra/azure/` stays as dead reference, same policy as `infra/aws`
  during the exile — with the caveat that its Pulumi state was deleted
  with the storage account, so it is code-only: redeploying Azure means
  re-running `foundation.sh` from scratch
- Pulumi backend login switched back to the S3 URL

`cluster/` untouched, again. The header comment now says "proven twice."

## Consequences

- Cost returns to ~$0.135/hr (t3a.medium × 3) — the burstable tier Azure
  never let us have. Idle cost: pennies of S3.
- The old backups in the bucket predate the Azure-era schema changes
  (the `netbox` role/database exist only in Azure-era backups, which are
  gone). First `make up && make bootstrap && make platform` starts fresh
  WAL history; the surviving base backups are restorable curiosities from
  the 7.4/pre-suspension era, and barman's 7d retention will age them out.
- The Azure-specific lessons stand as documentation: the three-layer
  quota model, `inheritFromAzureAD` on kubeadm, the ScopeLocked/role-
  assignment interaction, resource-group-native lifecycle boundaries.
- `make login` is `aws sso login` again. Session cadence returns to
  SSO-expiry rhythm rather than `az login`.
