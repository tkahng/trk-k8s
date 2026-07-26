# ADR 006 — Patroni HA on the Kubernetes-API DCS, custom image

Date: 2026-07-25. Status: accepted, implementation starting (Phase 7.3).

## Context

Phase 7.3 adds automatic failover to the hand-built Postgres from 7.1/7.2
via **Patroni**: a supervisor that runs as PID 1 in each Postgres pod,
bootstraps replication, and holds a leader lease in a **DCS** (distributed
consensus store). Two decisions gate the build: which DCS, and which
container image (the official postgres image ships no Patroni; the Patroni
project ships no production image).

Topology constraint that shapes both: 1 tainted control plane + 2 workers
on 4GB nodes. A ZooKeeper ensemble wants 3 members and ~3 JVMs — a
placement and memory problem. PLAN.md explicitly wanted the DCS options
compared before choosing.

## Decision

1. **DCS: the Kubernetes API itself.** Leader election happens via
   annotations on an Endpoints object; consensus is delegated to the
   control plane's existing etcd. Zero new components, election observable
   with `kubectl`, and a 2-member Patroni cluster (one per worker) is
   sound because Patroni members don't vote among themselves — the DCS
   holds the quorum. Requires RBAC (ServiceAccount + Role to read/patch
   endpoints, configmaps, pods) — a lesson in itself.
2. **Eyes-open trade-off, to be drilled:** this couples Postgres write
   availability to the control plane. If Patroni cannot refresh its lease
   (apiserver down), the leader **self-demotes** after the TTL — fencing
   against split-brain. Drill 3 proved "control plane down ≠ outage";
   this choice creates the exception, and Phase 7.3's drills will
   demonstrate it deliberately.
3. **ZooKeeper stays a comparison lab, not the build** — same reasoning
   as ADR 004's Talos deferral: learn the layer explicitly later, on top
   of a working baseline, if appetite and headroom allow.
4. **Image: custom-built** — `FROM postgres:18` + `pip install
   patroni[kubernetes]`, with `patroni.yml` **hand-written** as a
   ConfigMap. This follows the 7.2 precedent (declined the pgbouncer
   image's env-var config generation; writing the config is the lesson)
   and keeps postgres:18 continuity, including 7.1's volume-layout
   knowledge. Spilo (Zalando's bundle) was rejected for the same reason
   the edoburu env-var path was: it generates the config we're here to
   understand.

## Consequences

- A container registry enters the project (GHCR) — build/push plumbing
  and, if the image stays private, an imagePullSecret on the cluster.
- pgbouncer's upstream moves from `postgres-0.…` to the Patroni-managed
  **leader Service** — apps keep connecting to `pgbouncer.postgres.svc`
  and should notice nothing during failover (the 7.2 indirection paying
  off).
- Failover behavior lives in hand-written numbers we now own:
  `ttl` / `loop_wait` / `retry_timeout`, and async-vs-synchronous
  replication (default async ⇒ RPO > 0 on hard failover; to be
  demonstrated with marker rows).
- Two members, two local-path PVCs, one per worker — replication syncs
  the data, not storage. Losing a worker now loses one *replica*, not
  the database.
