# 2026-08-18 — Drill 1: failover under load, or: the pod that held the door

First of the five capstone drills, on the Azure/Premium-disk cluster.
Setup: NetBox serving 4 req/s of authenticated API traffic (laptop,
through a port-forward), a `drill-writer` pod in-cluster inserting a
timestamped row through `pg-pooler-rw` every 500ms, and a watcher on the
CNPG cluster's `currentPrimary`/`phase`. Trigger: `kubectl delete pod
pg-1` — the primary — fired by hand.

## The numbers

| moment | UTC |
|---|---|
| delete lands, phase → `Failing over` | 08:34:55 |
| writes STILL flowing on the terminating pg-1 | → 08:37:53 (~3 min) |
| last write before the gap | 08:37:53.771 |
| pg-2 reported as primary | 08:38:12 |
| first write after the gap | 08:38:24.356 |
| healthy again, 2/2, pg-1 rejoined as replica | 08:38:36 |

- **Write outage: 31.1s** (largest gap in the tick table; every other gap
  among 761 rows was <0.8s)
- **App-visible: 8 failed requests of ~124** sent inside the window —
  a few client timeouts and a single 500
- **Data lost: zero.** One clean hole in the ticks, no corruption. The
  PVC survived the pod, so pg-1 came back as a replica with no re-clone.

## Finding 1 — a graceful delete is a switchover wearing failover's clothes

The most surprising row in the table: the "dead" primary accepted writes
for **three minutes after the delete**. `kubectl delete` is polite —
CNPG's instance manager uses the termination grace to run an orderly
handover (shutdown checkpoint on pg-1, then promotion of pg-2), and the
`kubectl delete` command itself hangs until the pod finally exits — long
enough that the terminal reported a 2-minute timeout while the delete
kept going server-side.

So this drill measured the ORDERLY path: 31s of write unavailability,
scheduled at the operator's convenience. The brutal path — node loss, or
`--grace-period=0 --force` — skips the checkpoint courtesy entirely and
is a different (future) measurement. Lesson: **"delete the primary pod"
is not a crash test.** If you want crash semantics, you have to actually
crash something.

## Finding 2 — the pooler turned 31 seconds of outage into 8 errors

124 requests entered a window with no writable database; 116 came out
fine. PgBouncer doesn't refuse clients when the backend vanishes — it
HOLDS them, then replays onto the new primary once the rw Service
repoints. The app never knew there was a failover; it just saw a few
slow pages. The pooler added in 7.4 to "close the pooler gap" earned its
place in one drill.

## Finding 3 — centralized promotion, revisited

The 7.3 Patroni stack held elections inside the pods (and self-fenced on
apiserver loss). CNPG's pods never voted: the operator decided, the
PRIMARY label moved exactly once (pg-1 → pg-2, visible at 08:38:12), and
there was no split-brain window to reason about. Same conclusion as the
7.4 apiserver-fence drill, now measured under load.

## Residue

- `drill_ticks` table stays in the netbox database — 761 rows with one
  31-second hole is exactly the kind of evidence the restore drill
  (drill 4) can replay against.
- pg-2 is now the primary; pg-1 the replica. No action needed — CNPG
  does not fail back on its own, and there is no reason to.
