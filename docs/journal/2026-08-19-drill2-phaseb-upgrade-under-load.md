# 2026-08-19 — Drill 2, Phase B: the migration was innocent

The drill's premise: upgrading NetBox (chart 8.3.46→8.3.57, app
v4.6.7→v4.6.8) while two pods serve one schema under 4 req/s of load,
watching for migration locks and version-skew errors. The finding: **the
schema migration was a non-event; the delivery machinery around it caused
a nine-minute outage.** Upgrades fail at the edges, not the center.

## The numbers

| | buggy roll | fix roll (down-first + pinned valkey) |
|---|---|---|
| duration | 04:07:48 → 04:30:18 (unblocked by hand twice) | 04:31 → 04:33:26, unattended |
| failed requests | **2,145** of 4,732 | **153** (one ~38s window) |
| migration locks observed | 0 at 3s sampling | — |
| manual interventions | 2 | 0 |

Migrations (including v4.6.8's new index set, `wireless.0017–0020`)
applied exactly once, invisibly fast. Django's migration machinery was
never the risk.

## Bug 1 — the lookup trap's last victim

The Valkey password was the ONE secret still chart-generated (every
NetBox secret was pinned back in 7.5 for exactly this reason). Helm's
`lookup` returns empty under `helm template`, so ArgoCD's re-render of
the upgraded chart minted a fresh password: secret rv 25159→30429,
Valkey restarted 04:09:36 — and the load generator's first 500 is
stamped THE SAME SECOND. Every running pod died on stale cache
credentials; Django's error page said `AuthenticationError`, ~10ms per
request — too fast to be the database, which is the tell.

An earlier symptom had already fingerprinted this: after the node
recoveries, one pre-resize pod 500'd forever while its younger twin was
fine — same rotation, different vintage. Pods don't re-read secrets;
they carry the credentials of their birth era.

Fix: `netbox-valkey-pinned` from `~/.config/trk-k8s/netbox-valkey-password`
(platform.sh generates it; values point the subchart AND the netbox
projections at it — verified by `helm template` before committing).
Chart-generated secrets under GitOps aren't config, they're time bombs
with a per-sync fuse.

## Bug 2 — hard anti-affinity + surge = deadlock at replicas == nodes

RollingUpdate's default maxSurge needs room for an EXTRA pod. Required
anti-affinity (one web pod per node) means that room does not exist on a
two-worker cluster running two replicas: the surge pod goes Pending
forever while the old pods — already broken by bug 1 — squat both nodes
unready. The deployment can neither advance nor retreat; it took manual
deletion of the squatters, twice, to finish the roll.

Fix: `maxSurge: 0, maxUnavailable: 1` — roll DOWN first. The fix-roll
itself was the proof: 2½ minutes, no deadlock, no hands. The 153
failures were the one-time cost of migrating Valkey to the pinned
password (the last old-template pod broke the moment Valkey restarted
with it — the final expression of bug 1, dying with the template that
carried it).

## Verdicts on the drill's three questions

1. **Migrations exactly once?** Yes — uncontested, both entrypoints ran
   `migrate`, Django's own locking made the second a no-op.
2. **DDL lock impact?** None observable at 3-second sampling against
   4 req/s. Index-only migrations on a small schema are free.
3. **Old code against new schema?** Never got to matter — additive
   index migrations are the compatible kind. A column-dropping upgrade
   would tell a different story; that's a future lab, not this chart
   bump.

Also checked: 8.3.57 STILL doesn't project `superuser_api_key` into
`/run/secrets`, so populate.sh's token self-heal remains load-bearing.

## Where drill 2 ends up

Phase A taught capacity honesty (three node-wedges, one arithmetic
fact — see 08-18). Phase B taught delivery honesty: the two artifacts
that broke were both OURS (a secret we hadn't pinned, a strategy we
hadn't reconciled with our own affinity rules), and both fixes are now
permanent, in git, and were proven by their own deployment. The
database — the thing the drill was nominally about — never blinked:
zero data loss, zero lock contention, migrations clean through two
chaotic rollouts and a mid-flight credential rotation.
