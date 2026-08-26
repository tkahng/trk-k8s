# 2026-08-26 — Drill 4: restore with the app attached

The drill the capstone was built for: delete real records, rebuild the
database from object storage to the moment before the mistake, and prove
recovery at the APPLICATION — not a psql prompt (that was 7.4), but
NetBox itself serving the resurrected data.

## First, the blocker that almost made the drill a lie

Preflight found the fresh post-rebuild cluster with
`ContinuousArchiving=False`, stuck on its very FIRST WAL segment:
`Expected empty archive`. CNPG refuses to let a new cluster archive into
a blob prefix holding a dead generation's WALs — and the refusal is
silent at the app level: every ArgoCD app green, zero backups happening.
Which means the 08-18 rebuild almost certainly ran drills 1–3 with no
working backups at all. `archived_count` lies (7.4); now we know entire
GENERATIONS can lie.

Fix: per-generation `serverName` (`pg-20260825`), and bumping it is now
resume-runbook step 1b. The drill then used the naming properly: the
recovery bootstrap references the origin generation's serverName, and
the restored cluster archives under its own.

## The drill

| moment | event |
|---|---|
| 23:32:55 | on-demand base backup (verified by LISTING the archive) |
| ~23:45 | populate.sh fills the database — this data exists ONLY in WAL |
| 23:51:34 | **the oops** (fired by hand): DELETE VM k8s-worker-2 → HTTP 204, cascading to its interface + 2 IPs |
| 23:52:0x | post-oops evidence row written; `pg_switch_wal()` forces the segment into the archive (the open-segment lesson, applied deliberately) |
| +1 min | `pg-restore` Cluster applied: bootstrap.recovery from blob, `targetTime: 23:51:30+00` |
| +35 s | full-recovery job COMPLETED (base backup + WAL replay, 5Gi, Premium disks) |

## Three verdicts, all pass

1. **worker-2 exists** in the restored database (3 VMs) — proof of WAL
   replay, since populate ran after the base backup.
2. **The evidence table does not exist** — PITR stopped at 23:51:30,
   surgically excluding the four seconds containing the delete and
   everything after. Point-in-time means point-in-time.
3. **The restored cluster archives immediately** under
   `pg-restore-20260825` — a restore that doesn't resume backups isn't
   done.

Then the app: NetBox repointed via git to `pg-restore-rw`, rolled with
the down-first strategy, and answered the API with **3 VMs including
k8s-worker-2** — the deleted machine back in the UI, everything after
the target gone. That sentence is the whole capstone.

## The closer (the part restore stories skip)

Living on the side-cluster isn't recovery, it's squatting. NetBox was
repointed BACK to the canonical `pg` (whose database still had the
hole), and the hole was healed by re-running populate.sh — idempotent
GET-then-POST recreated exactly the missing objects and nothing else.
`pg-restore` decommissioned; its manifest stays in git as the reference
recovery procedure. End state: canonical GitOps topology, all data
present, archiving green.

Two interruptions worth logging: the admin IP drifted MID-DRILL (second
time this era — the NSG admits one /32 and laptops move; 7-second fix)
and a verification watcher hung on its own bad grep (the DB host renders
into a ConfigMap, not pod env). The drill absorbed both.

## Follow-up with a deadline

CNPG now warns at apply time: in-tree `barmanObjectStore` is REMOVED in
1.31. The Barman Cloud Plugin migration deferred in 7.4 has a clock on
it — before any operator upgrade past 1.30, backups must move to the
plugin, or this entire drill's machinery stops existing.
