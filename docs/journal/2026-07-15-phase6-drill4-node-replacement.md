# 2026-07-15 — Phase 6, Drill 4: node replacement (unannounced)

Terminated k8s-worker-2 at the AWS level — no drain, no warning. Timeline:

| T+ | Event |
|---|---|
| 0:00 | `aws ec2 terminate-instances` |
| 0:54 | Node NotReady (kubelet heartbeat timeout ~40s + detection) |
| — | Deleted the node object (skips the default **5-minute** not-ready toleration before pod eviction — k8s hedges against network blips; we knew it was a corpse) |
| ~2:00 | `pulumi refresh` noticed the terminated instance; `pulumi up` recreated it in 15s, same private IP (fixed addressing pays off) |
| ~7:00 | `make bootstrap` (unchanged, idempotent) prepped + joined the replacement: Ready at 58s old, already at v1.36.2 (prep-node bump working) |

## The point

There is no "node replacement procedure." It's the same two commands as
everything else — `pulumi up` + `make bootstrap` — because the scripts are
idempotent and the machine carries no identity that matters. Nodes are
fully cattle now.

## Notes

- kubelet heartbeat → NotReady in under a minute; pod eviction waits
  another 5 min by default (tolerations added to every pod automatically).
  For known-dead nodes, `kubectl delete node` short-circuits.
- The stale node object must be deleted anyway before a same-name
  replacement joins cleanly.
- hello replicas were both on worker-1 (evicted there during drill 2) —
  a reminder that after maintenance, workloads sit wherever history put
  them. `kubectl rollout restart` or a descheduler rebalances if it
  matters.

## Phase 6: complete

Automation + 4 drills done (rebuild ~8min / rolling upgrade zero-downtime /
etcd time-travel / node replacement ~7min). Stretch items (HA control
plane, Hetzner portability proof) parked. Next: Phase 7 — Postgres.
