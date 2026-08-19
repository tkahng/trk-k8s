# 2026-08-19 — Drill 3: cache vs queue, both predictions inverted

Setup: 4 req/s of authenticated API load with per-request latency, five
RQ jobs scheduled 30 minutes out (bodies planted IN Valkey at kill time),
persistence facts recorded beforehand (AOF on — bitnami default — RDB
stale), watcher on the pod. Trigger, fired by hand:
`kubectl -n netbox delete pod netbox-valkey-primary-0`.

## The numbers

- Total incident: **~35s** pod-gone-to-ready; app-visible window **22s**
- Failed requests: **62** (61× HTTP 500, 1 timeout) — of 414 in the log
- Queue bodies: **5 of 5 survived** the AOF replay; scheduled registry
  identical before and after
- Latency: 49–52ms before, 56ms in the recovery bucket, 50ms after —
  **no measurable re-warm penalty**

## Both textbook predictions were wrong

**"Queue loss is real work loss"** — not here. The drill card was
written assuming in-flight jobs die with the pod. In fact bitnami's
Valkey ships appendonly-yes onto a PVC, and a StatefulSet pod comes back
as ITSELF (same name, same volume): the AOF replayed and every job
survived. The queue's real RPO is appendfsync's ~1 second, not "the
pod's lifetime". Durability was configured in by a default nobody chose
on purpose — worth knowing it's there, and worth knowing drill 4 would
be the drill where it matters (local-path PVC dies with the NODE).

**"The cache degrades gracefully"** — absolutely not. NetBox returned
500 for every request while Valkey was down. Sessions and config caching
are LOAD-BEARING: this is a hard runtime dependency wearing a cache's
name. Phase B's password rotation was the same fact in different
clothes (9 minutes of 500s). And once Valkey returned, latency was
instantly normal — at lab scale the feared re-warm is a ghost.

## The failure hierarchy, now measured

| failure | blast | recovery |
|---|---|---|
| Valkey pod killed | 22s of 500s | self-healing, zero hands |
| Valkey password rotated (phase B) | 9 min of 500s, all pods | manual, twice |

Infrastructure death is cheaper than configuration betrayal. The pod is
cattle; the credential is a contract.

## Residue

- Drill bodies cleaned from the scheduled registry (count back to
  baseline housekeeping).
- Open thread for drill 4/5 territory: Valkey's durability rides a
  local-path PVC, so node loss (not pod loss) is where the queue
  actually dies. The cache-vs-queue asymmetry exists — it just lives
  one failure domain further out than the textbook says.
