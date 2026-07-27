# Patroni: how Postgres HA actually works (Phase 7.3 companion)

Patroni is not a fork of Postgres and not an operator — it's a supervisor
that runs as PID 1 in each Postgres pod, wrapping the database. It
bootstraps replication, and continuously answers one question — *who is
the leader?* — using a **DCS** (distributed consensus store). Ours is the
Kubernetes API itself (ADR 006). The config it runs from is hand-written
in `apps/postgres/base/patroni-config.yaml`; this note is the conceptual
companion to that file's inline comments.

## The mental model: two kinds of config in one file

Some of `patroni.yml` configures **the daemon in this pod**; some of it
seeds **the cluster as a shared thing**. Mixing those up is the classic
Patroni confusion.

| Block | Controls | Read when |
|---|---|---|
| `scope` / `name` | who I am, which cluster I belong to | every start |
| `restapi` | the HTTP control surface on :8008 | every start |
| `kubernetes` | where leader election is stored (the DCS) | every start |
| `bootstrap` | cluster creation + the failover contract | **once ever**, by the first member |
| `postgresql` | how to run *my local* Postgres | every start |
| `tags` | per-member flags (`nofailover`, …) | every start |

`bootstrap.dcs` is the trap: it is written into the DCS at cluster
creation and never read from the file again. Live cluster config is
edited with `patronictl edit-config` — editing the ConfigMap later does
nothing (until a whole new cluster bootstraps from scratch).

## The lease, and the numbers that define failover

The leader holds a lease in the DCS and renews it every loop. The knobs
(rule of thumb: `ttl >= loop_wait + 2*retry_timeout`):

| Knob | Ours | Meaning |
|---|---|---|
| `ttl` | 30 | lease lifetime — max leaderless time before failover starts |
| `loop_wait` | 10 | each member's heartbeat: wake, check DCS, act, sleep |
| `retry_timeout` | 10 | how long DCS/postgres ops may fail before "down", not "slow" |
| `maximum_lag_on_failover` | 1 MiB | a replica further behind is disqualified from promotion |

`ttl` is simultaneously the **detection time** (hard-killed leader
noticed within ≤30s) and the **fencing clock**: a leader that cannot
reach the apiserver self-demotes when its lease would have expired,
because it must assume someone else won it. That is what prevents
split-brain — and it's the price of the k8s-API DCS: control-plane
outage becomes a Postgres *write* outage (the deliberate exception to
drill 3's "control plane down ≠ outage"; see ADR 006).

## Election, on the Kubernetes API

With `use_endpoints: true`, the lease is annotations on the
**Endpoints named after the scope alone** — `postgres`, not
`postgres-leader`: Patroni's `kubernetes.py` strips the `-leader`
suffix in this mode (only `-config`/`-failover`/`-sync` keep theirs) —
and Patroni also writes the leader pod's IP into its subsets. The
matching scope-named Service has no selector — Patroni is the sole
author of what's behind it. So the election result *is* the routing
change, in one atomic write.

**The collision gotcha (found the hard way):** the scope name doubles
as the leader Service name, so nothing else may claim it. Our headless
governing Service was originally named `postgres` — a selector Service,
whose Endpoints the endpoints controller owns. Patroni lost the CAS to
the controller every cycle, logged only `Could not take out TTL lock`
(no error — the write "succeeded" and was immediately reverted), and
after bootstrap **fenced itself** (`Demoting self (immediate-nolock)`),
leaving a cluster with an initialize key and no leader. Fix: headless
Service renamed `postgres-pods`; `postgres` became the selector-less
leader Service. This is why Zalando clusters name the primary Service
after the cluster itself.

**The scope-label gotcha (same evening):** Patroni finds its member
pods with `kubernetes.labels` **plus `scope_label=scope` appended
automatically** (`kubernetes.py:756`) — but it only ever stamps the
*role* label on pods, never the scope label. Pods missing
`cluster-name=<scope>` are invisible to the member watch: elections
still work (the lock write needs no member list), but a replica can't
resolve the leader's `conn_url` — `create_replica` filters basebackup
out of an empty method list and fails in ~1ms with a bare "failed to
bootstrap from leader". The pod template must carry the scope label
itself. Both gotchas are journaled in
`2026-07-26-phase7.3-patroni-bootstrap.md`, along with the third
(StatefulSet `OrderedReady` deadlocks when the initialized data lives
on a higher ordinal — Patroni owns bootstrap ordering, so
`podManagementPolicy: Parallel`).

Atomicity comes from Kubernetes optimistic concurrency: two candidates
race to update the annotation; the apiserver (backed by the control
plane's etcd — where the consensus really lives) accepts exactly one.
Compare-and-swap, delegated. Watch it live:

    kubectl -n postgres get ep postgres -o yaml          # holder + renewals
    kubectl get pods -n postgres -L role                 # patroni-stamped roles

`role_label` is the second mechanism: Patroni stamps each pod
`role=primary|replica` (hence RBAC `pods/patch`) — what a read-only
replica Service would select on.

## Rejoining after defeat: pg_rewind and slots

- `use_pg_rewind` — a deposed leader's timeline has diverged (it may
  hold commits the new leader never saw). `pg_rewind` rewinds it to the
  divergence point so it rejoins as a replica in seconds instead of
  re-cloning the database.
- `use_slots` — the primary retains WAL per connected replica so a
  brief disconnect means catch-up, not re-clone; `wal_keep_size` bounds
  the retention so a *dead* replica can't fill the disk.
- Async replication (our default) ⇒ RPO > 0: a hard failover can lose
  the last commits, bounded by `maximum_lag_on_failover`.
  `synchronous_mode` trades write latency for zero loss — a 7.3 drill
  contrast.

## The runtime story, end to end

Pod starts → Patroni (PID 1) reads patroni.yml + `PATRONI_*` env
overrides → connects to the apiserver → **is there a `postgres-config`
for scope `postgres`?**

- **No** → I'm first: `initdb`, create superuser + `replicator`, write
  `bootstrap.dcs` into the DCS, take the lease, open for business.
- **Yes, with a leader** → `pg_basebackup` from the leader's
  `connect_address`, start streaming, loop every 10s.
- **Leader vanishes** → lease expires within `ttl` → survivors compare
  WAL positions via each other's REST APIs (:8008) → the freshest
  writes itself into the scope-named Endpoints (apiserver arbitrates the race)
  → promotes. pgbouncer's next transaction lands on the new primary
  with zero config change — the 7.2 indirection paying off.

Patroni owns the lifecycle the docker entrypoint used to own: there is
no `POSTGRES_PASSWORD` env and no entrypoint script; Patroni invokes
`initdb`/`pg_ctl` from `bin_dir` itself. Passwords reach it only as
`PATRONI_SUPERUSER_PASSWORD` / `PATRONI_REPLICATION_PASSWORD` env from
the `postgres-credentials` Secret — nothing in git (7.2 ethos).

## Where this sits vs "best practice"

Production best practice is an **operator** — CloudNativePG (no Patroni:
its own instance manager on the k8s API), Zalando postgres-operator
(Patroni/Spilo underneath), Crunchy PGO (Patroni underneath; renders
Patroni YAML into a ConfigMap much like ours). Nobody hand-writes
patroni.yml per production cluster; operators also reconcile dynamic
config continuously, closing the file-vs-DCS drift gap we merely
comment about. Hand-rolling is 7.3's point: build the layer once, then
judge in 7.4 what the operators automate. Patroni's own k8s demo goes
all-env (`PATRONI_*` only, no file); we chose the structured file
because it teaches Patroni's actual config model, the one the docs and
`patronictl` speak.
