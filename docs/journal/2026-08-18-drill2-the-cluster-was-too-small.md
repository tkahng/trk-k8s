# 2026-08-18 — Drill 2, Phase A: the cluster was too small, three ways

Drill 2 was written to study schema migrations under multiple app
replicas. Phase A — just scaling NetBox from 1 to 3 pods — instead spent
an afternoon killing worker nodes, and every kill taught something the
migration part never would have. Phase B hasn't run yet; these findings
deserved their own entry.

## The three wedges (one arithmetic fact, three disguises)

**Wedge 1 — the request was a lie.** Each NetBox web pod requests 512Mi
but spikes past 1.5Gi at boot (four gunicorn workers warming caches; the
26-OOMKill discovery from the bring-up, seen from the other side). The
scheduler packs by requests, so it placed two booting pods on one 4Gi
worker. The node didn't OOM-kill a container — it thrashed at the NODE
level until kubelet stopped posting status; the taint manager then
evicted everything. Fix: requests raised to 1536Mi. **A request is a
promise to the scheduler; break it and the scheduler breaks your node.**

**Wedge 2 — the web tier was never stateless.** Honest requests changed
nothing, because the chart mounts a shared `netbox-media` volume on
every web pod, and an RWO local-path PVC is node-affine: every replica
was PINNED to worker-1. The scheduler was never allowed to spread
anything — colocated boot spikes again, same death. The tell in the
scheduler event: a *web* pod failing with "didn't match PersistentVolume's
node affinity". Fix: media persistence off (uploads unused; truth lives
in Postgres) plus hard pod anti-affinity, one web pod per node.

**Wedge 3 — the other pods lie too.** With the pin gone, the second
replica landed on the OTHER worker and killed that one: it hosted the
platform stack (ArgoCD, Valkey, RQ worker...), much of which declares no
requests at all. "1536Mi bookable" and "1536Mi actually free" are
different numbers when your neighbors are unaccounted. Scheduling honesty
is a property of the WHOLE node, not of one workload.

## The wedge-recovery choreography (now proven three times)

A memory-wedged node shows `VM running` in Azure while SSH hangs at
banner exchange. `az vm restart` pays the hung-guest tax (~10-15 min:
Azure waits out graceful shutdown before force-cycling). And the first
two recoveries failed the same way: the node came back, the scheduler
instantly re-dumped the SAME doomed pods onto it, and it wedged again —
a rolling update keeps the old ReplicaSet alive until new pods go Ready,
so the murder weapon respawns. Working procedure:

1. `kubectl cordon` the node (nothing can storm it on return)
2. force-delete the pods bound to it (`--force --grace-period=0`) and,
   if a rollout is stuck, delete the old ReplicaSet outright
3. `az vm restart`, wait for Ready-while-cordoned
4. uncordon into a config that cannot re-create the storm

## The bonus incident: pg_rewind deadlocked on a WAL file that no longer exists

Wedge 1 took worker-1 down with pg-2 on it — which was the PRIMARY
(drill 1 had promoted it). CNPG failed over to pg-1 unprompted: the real
crash-test failover drill 1 couldn't measure, performed by accident.

But pg-2's rejoin then hung forever on "Waiting for the instances to
become active". The logs told the truth the status hid: pg-2 diverged on
its old timeline, pg_rewind needed the WAL segment that was OPEN when
the node died — never archived (RPO = the open segment, now biting
REJOIN instead of restore), no longer on disk. The operator retried the
impossible rewind forever rather than escalating. **"Waiting" and
"deadlocked" look identical from the status field; go read the instance
logs.** Fix (runbook 07): delete the instance's PVC + pod; the operator
re-clones from the live primary — 32 seconds for 5Gi on Premium disks,
versus 40 minutes of retrying the impossible.

## The verdict: resize (ADR-worthy arithmetic)

A 4Gi worker minus OS, kubelet, Cilium, a CNPG instance and the platform
stack leaves roughly ONE NetBox boot spike of headroom. Two workers,
two-to-three spikes needed: no scheduling cleverness changes that — it
only picks which node dies. Options were replicas=1 forever (guts the
drill and leaves 3-5 at the same cliff edge) or 8Gi workers. Credits
expire Sept 4 regardless: workers went D2als_v7 → D4als_v7 (quota-exact,
2+4+4 = 10/10 family vCPUs), and `infra/aws` got the same medicine
dormant (t3a.medium → t3a.large) so the next AWS era doesn't rediscover
the wedge. All the honesty fixes stay — bigger nodes end the failure
class, they don't excuse the lies.

## Also collected along the way

- The full destroy → up → bootstrap → platform → populate cycle ran
  hands-off mid-drill (an accidental drill 5 dry run), and populate.sh's
  token self-heal fired visibly on the fresh database: "token not
  accepted — minting v2 token via the ORM".
- Admin IP drift locked us out again (NSG admits one /32; laptop moved
  networks). `check-ip` only runs on `make up` — a long-lived cluster
  accumulates drift silently. One `pulumi config set myIp` + 7s apply.
- A background watcher waiting for "netbox 3/3" outlived the decision
  that made 3/3 impossible and ran 18 hours as a zombie. Watchers need
  deadlines or tripwires: a condition that can silently become
  unsatisfiable is the monitoring version of the pg_rewind loop.
