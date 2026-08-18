# ADR 011 — Azure again: burn the credits, with a hard deadline

Date: 2026-08-17. Status: accepted, in progress.

## Context

The Azure credits granted at signup turn out to be valid until **Sept 4**.
ADR 010 emptied the subscription to zero because an idle pay-as-you-go
subscription bills forever — but a subscription with weeks of credit left
bills nothing *while the credits last*. Leaving them unused buys nothing;
the AWS cluster was `make destroy`ed on 2026-08-17 and both S3 buckets
(state + backups) stay parked at pennies.

So: third provider swap. aws→azure (ADR 009), azure→aws (ADR 010), and
now aws→azure again — this time by choice rather than necessity, which
makes it the first *routine* swap. The procedure is now a runbook section
(runbook 06), not an ADR narrative.

## The discovery: deterministic names made the teardown cheap

ADR 010 warned that redeploying Azure "means re-running foundation.sh
from scratch" because the Pulumi state died with the storage account.
True — but cheaper than it sounded, for one design reason:

**foundation.sh derives globally-unique names from a hash of the
subscription id** (`shasum` of the sub id, first 8 chars). Same
subscription → the same storage account (`sttrkk8sf92a7ab3`), the same
Key Vault (`kv-trk-k8s-f92a7ab3`), and — because RG and identity names
are fixed strings — the same node-identity resource ID. The committed
`Pulumi.dev.yaml` written before the teardown is therefore still correct
after rebuilding from absolute zero. A random suffix (the common pattern)
would have invalidated every one of those references.

The single casualty is `encryptedkey`: the stack's data key was wrapped
by the purged vault key, and purge destroys key material unrecoverably —
same key *name* recreated ≠ same key. Since no stack config values are
encrypted secrets, the fix is: delete the stale `encryptedkey` line and
let a fresh `pulumi.sh stack init dev` mint a new one against the new
backend. That stack-init step is the only addition to the bring-up
compared to a provider whose state survived.

## The asymmetry, now stated plainly

- **AWS parks well.** Suspension preserved everything (ADR 010); a
  deliberate park costs pennies of S3 and the return is `make up`.
- **Azure at $0 requires deleting the state backend itself**, so every
  Azure return pays the foundation rebuild + stack init toll. Acceptable
  because foundation.sh is idempotent and the names are deterministic —
  by design, not luck.

## Consequences

- ~$0.256/hr (D2als_v7 ×3, eastus — quota verified 0/10 used on both
  gates), covered by credits.
- **Teardown before Sept 4 is a deadline, not a habit**: the subscription
  has NO spending limit (removed during the ADR 009 quota saga). After
  expiry, anything left running bills real money silently.
- CNPG backups target the blob container again; the netbox flow arrives
  with the corrected v2 API token pair, so this bring-up is the first
  fresh-cluster test of populate.sh's token self-heal.
- The AWS-era backups in `s3://trk-k8s-pg-backups` sit unpruned (barman's
  retention only runs from inside a live cluster). Pennies; cleaned up
  whenever AWS hosts a cluster again, or manually.
