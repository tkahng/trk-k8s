# 2026-08-06 — Azure to zero, AWS resumed from a time capsule

The AWS account came back. Azure — pay-as-you-go, no spending limit — had
to go to literally zero, and the return to AWS turned out to be a resume
rather than a rebuild.

## The discovery that shaped everything

**A suspended AWS account keeps its resources.** Both buckets survived:
`tkahng-pulumi-state` with both stacks intact (dev cleanly at 0, persistent
with all its resources), and `trk-k8s-pg-backups` with **9 backup objects**
— the 6-hourly ScheduledBackup kept firing until the moment of suspension.
`pulumi preview` on the persistent stack: **unchanged**. The passphrase
file and `~/.ssh/aws_k8s` never left the laptop.

So ADR 008's lifecycle boundary held across an account suspension — a
harsher event than any drill we designed. The backups outlived their own
account's accessibility.

The asymmetry with Azure is the lesson: AWS suspension *preserves*;our
Azure exit *deletes forever*, deliberately, because an idle subscription
with a locked resource group bills for storage indefinitely.

## Azure teardown (order mattered)

The state describing the cluster lived inside the storage account being
deleted — cluster first, state last. The cluster RG was already gone
(the final `make destroy` had completed), so:

lock off → `rg-trk-k8s-persistent` deleted → **Key Vault purged** from
soft-delete (7-day name hold otherwise) → `NetworkWatcherRG` deleted
(auto-created by Azure; took two attempts) → service principal deleted →
**two orphaned role assignments** swept (they outlive their principal as
`principalName==''` entries) → local `azure-*.env` credential files
removed.

Verified end state: **0 resource groups, 0 resources, no soft-deleted
vaults.** The subscription can no longer bill anything.

## The return (repo)

Makefile restored from git history (`git show c9b6d69^:Makefile`) —
INFRA_DIR/SSH_KEY/AWS_PROFILE/passphrase-PULUMI/`persist-*` targets/
`aws sso login` — keeping the post-Azure `--provider=aws` explicitness.
platform.sh default back to `aws` (azure branch retained). CNPG
`barmanObjectStore` back to S3 + `inheritFromIAMRole`, keeping the
Azure-era additions (managed `netbox` role, `Database` CR, netbox
credential flow). `infra/azure/` stays as reference — **code only**: its
Pulumi state died with the storage account, so redeploying Azure means
`foundation.sh` from scratch.

`cluster/` untouched. Again. The Makefile header now says "proven twice."

## Note on the surviving backups

The 9 objects predate the Azure era, so they contain no `netbox`
role/database — restorable curiosities from 7.4, and barman's 7d
retention will age them out once archiving resumes. The first bring-up
starts a fresh WAL history against the old bucket.

## State / next

Azure: $0 forever. AWS: previews clean, `make up && make bootstrap &&
make platform` away from a cluster (~$0.135/hr — the burstable tier Azure
never let us have). Then: NetBox populate script (`apps/netbox/
populate.sh`, committed), and the five-drill capstone card, all unblocked.
