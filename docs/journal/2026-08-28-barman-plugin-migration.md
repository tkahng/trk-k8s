# 2026-08-28 — The barman plugin migration: three schema lies and a race

CNPG removes in-tree `spec.backup.barmanObjectStore` in 1.31. Every
backup, PITR, and rebuild-with-data capability this project has runs
through it, so this was a deadline rather than a preference. Done as a
**birth, not a migration**: the cluster had already been destroyed after
drill 5, so the next one came up plugin-native instead of taking a
rolling WAL-archiver switch on a live database. That choice paid for
itself three times over — every error below would have hit a working
database mid-rollout.

## Verified end to end (the only three questions that matter)

| proof | result |
|---|---|
| WAL archiving through the plugin | `ContinuousArchiving=True` under `pg-gen4-20260827` — a prefix that never existed before |
| Data recovered THROUGH the plugin | 3 VMs, 9 IPs, 4 prefixes — read from `pg-gen3-20260827`, an archive written by the **in-tree** implementation |
| Write path (`method: plugin` backup) | completed; blob listing shows `pg-gen4-20260827` with base:2 wals:6 |

The second row is the interoperability proof: the plugin reads archives
the old code wrote. Nothing in the object store had to be migrated —
only the configuration that points at it.

## Three schema lies, in order

1. **`retentionPolicy` is a string, not an object.** The upstream
   migration guide shows `retentionPolicy: {retention: "30d"}`; the CRD
   declares `type: string, pattern ^[1-9][0-9]*[dwm]$` and rejects the
   object outright. **Read the CRD, not the docs, when they disagree** —
   `kubectl get crd ... -o jsonpath='{...properties.spec.properties}'`
   settles it in one command.
2. **`serverName` is forbidden in the ObjectStore**: *"use the
   'serverName' plugin parameter in the Cluster resource."* The split is
   the better model and worth internalizing: an **ObjectStore describes a
   CONTAINER**; each Cluster picks its generation prefix inside it —
   writes via `plugins[].parameters`, reads via
   `externalClusters[].plugin.parameters`. One credential declaration,
   many generations.
3. **ArgoCD retries a failed sync with its ORIGINALLY rendered
   manifests.** Pushing a fix and hard-refreshing did nothing: attempts
   #4 through #7 replayed the same broken YAML. Each fix needed the
   in-flight `/operation` removed and an explicit sync at the new
   revision. Same family as 7.4's "automated sync doesn't retry exhausted
   revisions".

## The race that looked like nothing at all

With the schema finally valid, the Cluster still had **no status
whatsoever** for 30 minutes. The operator log held the answer:

    Pre-reconcile hook stopped the reconciliation loop
      identifier: barman-cloud.cloudnative-pg.io, Requeue: true

The plugin's hook had run ~15 seconds BEFORE the ObjectStore existed,
correctly refused to proceed, and requeued — but nothing re-triggered it
once the ObjectStore appeared. Meanwhile ArgoCD reported `Synced`, all
six apps looked healthy, and no database existed. `kubectl annotate
cluster pg` released it instantly.

Fix: `argocd.argoproj.io/sync-wave: "-1"` on the ObjectStore, so it is
always created before the Cluster. Ordering removes the race; the nudge
was a symptom cure.

Worth naming the pattern this project keeps rediscovering: **the
dangerous failures here are the quiet ones.** `archived_count` climbing
against an empty bucket (7.4), "Expected empty archive" leaving whole
generations backup-less while every app stayed green (08-25), and now a
Cluster with no status while GitOps declares success. None of them
raised an alarm; all three were found by looking at the thing itself —
listing the bucket, reading the instance logs, checking whether the
resource actually has a status.

## State

- Plugin v0.14.0 installed by `platform.sh` into `cnpg-system`
  (manifest URL, so not an ArgoCD source; and it must exist before the
  Cluster that declares it — same reasoning as the Gateway API CRDs).
  The manifest ships no Namespace object, so platform.sh creates it.
- `objectstore.yaml` holds destination + retention; the Cluster keeps a
  `plugins:` reference with `isWALArchiver: true`.
- `ScheduledBackup` moved to `method: plugin` — left on the default it
  would keep targeting machinery the Cluster no longer declares.
- The postgres image stays `system-trixie`. The plugin runs barman in
  its own sidecar, so `standard` is now defensible — but that is a
  separate, testable change, and this subsystem has already cost enough.

The 1.31 deadline is cleared: nothing this project depends on dies with
the in-tree code.
