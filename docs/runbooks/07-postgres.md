# Runbook 07 — Postgres in Kubernetes

Phase 7: two stacks, deployed side by side and deliberately kept that
way. The hand-built one (7.1–7.3) is the reference implementation; the
operator (7.4) is what we'd actually build on (ADR 007).

| | Namespace | What it is | Managed by |
|---|---|---|---|
| hand-built | `postgres` | StatefulSet + Patroni + pgbouncer, all hand-written | us, via git |
| operator | `postgres-cnpg` | CNPG `Cluster` + `Pooler` + `ScheduledBackup` | CloudNativePG 1.30 |

Both arrive via ArgoCD from `apps/`; nothing here is applied by hand
except drill artifacts (noted where they are).

## Prerequisites (both stacks)

- Cluster up per runbook 06 (`make up && make bootstrap && make platform`)
- Secrets, file-driven, never in git (`platform.sh` creates them):
  - `~/.config/trk-k8s/postgres-password` — superuser, hand-created
  - `~/.config/trk-k8s/postgres-replication-password` — **generated** by
    platform.sh if missing, newline-stripped (see gotchas)
- The CNPG operator arrives as its own ArgoCD Application sourcing the
  public Helm chart — `cluster/gitops/apps/cnpg-operator.yaml`, which
  **must** carry `ServerSideApply=true` (see gotchas). Since ADR 008 the
  Applications are themselves GitOps-managed by `root.yaml`.

## Connecting

Never connect to a pod directly — always through the pooler, so failover
is invisible to the client (the 7.2 indirection, which 7.3/7.4 then
tested):

    # operator stack (credentials are operator-generated)
    export KUBECONFIG=$(pwd)/kubeconfig
    PGPASS=$(kubectl -n postgres-cnpg get secret pg-app -o jsonpath='{.data.password}' | base64 -d)
    kubectl -n postgres-cnpg exec pg-1 -c postgres -- \
      env PGPASSWORD="$PGPASS" psql -h pg-pooler-rw -U app -d app -c '\dt'

    # hand-built stack
    kubectl -n postgres exec postgres-0 -- sh -c \
      'PGPASSWORD="$PATRONI_SUPERUSER_PASSWORD" psql -h pgbouncer.postgres.svc -U postgres'

Service map (operator): `pg-rw` primary only · `pg-ro` replicas only ·
`pg-r` any · `pg-pooler-rw` pgbouncer in front of `pg-rw`.
Hand-built: `postgres` = **the Patroni-managed leader** (selector-less)
· `postgres-pods` = headless per-pod DNS · `pgbouncer` = the pooler.

## Status at a glance

    kubectl cnpg status pg -n postgres-cnpg      # LSNs, lag per stage, slots, nodes
    kubectl -n postgres-cnpg get cluster,pods -L cnpg.io/instanceRole

    # hand-built equivalents
    kubectl -n postgres exec postgres-0 -- \
      patronictl -c /etc/patroni/patroni.yml list   # -c is REQUIRED, see gotchas
    kubectl -n postgres get ep postgres -o jsonpath='{.metadata.annotations.leader}'

## Drills

Method that made these trustworthy — reuse it:

1. **Plant a marker row through the pooler** before the disruption, then
   read it back after. Proves data survival *and* that the app path
   never changed. (Ported from drill 3's configmap time-travel markers.)
2. **Timestamp from the cluster's own events, not your stopwatch.** A
   watcher armed before a human-fired trigger measures your reading
   speed, not the failover. Use
   `kubectl -n <ns> get events --sort-by=.lastTimestamp`.
3. **Probes must not depend on the layer you're breaking.** kubectl dies
   with the apiserver, so the fence drill observes via SSH +
   `crictl exec` on the node, plus external curl for the control app.

### Planned switchover

    kubectl cnpg promote pg pg-2 -n postgres-cnpg          # operator
    kubectl -n postgres exec postgres-0 -- patronictl -c /etc/patroni/patroni.yml \
      switchover postgres --leader postgres-0 --candidate postgres-1 --force

Expect (CNPG): role swap 1s, pooler writes restored 2s, zero loss.
Expect (Patroni): ~10s, **then the pooler is stale** — see gotchas.

### Hard kill of the primary

    kubectl -n postgres-cnpg delete pod pg-1 --grace-period=0 --force

CNPG promotes the replica in ~2s (probe-based detection) and rebuilds the
dead one as a replica; app writes back at ~23s. **Do not cordon first** —
CNPG treats the cordon taint as a drain signal and gracefully evacuates
the primary before you can break anything (that's a feature; it also
invalidates the 7.3 drill recipe).

The hand-built stack needs the cordon, because otherwise the StatefulSet
controller resurrects the pod faster than Patroni's 30s `ttl` and no
failover occurs at all.

### Control-plane outage (the fence drill)

On cp-1, with watchers already running:

    sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/     # break
    sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/     # restore

Patroni self-fences within `ttl` → full write outage. CNPG keeps serving
indefinitely. Both are correct for their leadership model — ADR 007.

## Backups (operator only)

Config lives in `apps/postgres-cnpg/base/`: `barmanObjectStore` →
`s3://trk-k8s-pg-backups/`, credentials via `inheritFromIAMRole` (node
IAM role over IMDS, no Secret), plus a 6-hourly `ScheduledBackup`.

    # on-demand base backup
    kubectl cnpg backup pg -n postgres-cnpg
    kubectl -n postgres-cnpg get backup

    # VERIFY IN THE BUCKET — counters lie (see gotchas)
    aws s3 ls s3://trk-k8s-pg-backups/ --recursive --profile personal-admin

    # force a WAL segment to close (otherwise archiving waits for 16MB)
    kubectl -n postgres-cnpg exec pg-1 -c postgres -- psql -U postgres -tAc 'select pg_switch_wal()'

### Restore into a new cluster

Apply by hand (a drill artifact, not desired state — ArgoCD won't prune
it since it carries no tracking metadata):

    apiVersion: postgresql.cnpg.io/v1
    kind: Cluster
    metadata: {name: pg-restored}
    spec:
      instances: 1
      imageName: ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie
      storage: {size: 5Gi}
      bootstrap:
        recovery:
          backup: {name: <backup-name>}

**No `spec.backup` on the restore cluster** — a second cluster pointed at
the same `destinationPath` would archive over the original's WAL.

Recovery replays all *archived* WAL forward from the base backup, so
**RPO = the currently-open WAL segment** (measured in 7.4: exactly one
row lost of 660). Restore took 52s. Bound it tighter with
`archive_timeout` if that matters.

## Gotchas (each one cost real time)

**Operator / CNPG**

- `ServerSideApply=true` is mandatory on the operator's ArgoCD
  Application. CNPG's `Cluster`/`Pooler` CRDs exceed the 256KiB
  last-applied-annotation cap, so client-side apply silently installs
  9 of 11 CRDs and the operator crash-loops on `no matches for kind
  "Cluster"`.
- **Image variant is load-bearing.** `standard-*` images dropped the
  barman-cloud binaries (backups are migrating to the Barman Cloud
  Plugin). In-tree `barmanObjectStore` needs `system-*`.
- **`pg_stat_archiver.archived_count` lies.** With no destination
  configured, CNPG's archive command exits 0 — the counter climbed to 15
  and `ContinuousArchiving` read `True` while the bucket was empty. The
  only honest check is listing the bucket.
- `ScheduledBackup.spec.schedule` is **6-field** cron (seconds first),
  not 5-field Unix.
- Backup credentials are node-scoped via IMDS: any pod on the node can
  reach the bucket. IRSA is the correct fix; needs an OIDC provider.
- The bucket lives in `infra/aws-persistent` and survives
  `make destroy` (ADR 008). Create it once with `make persist-up`;
  `make up` fails without it (StackReference).

**Hand-built / Patroni**

- `patronictl` needs `-c /etc/patroni/patroni.yml`. It doesn't read the
  daemon's config; without it you get `KeyError: 'labels'`.
- The **leader Service must be named exactly the scope** (`postgres`):
  in `use_endpoints` mode Patroni strips `-leader`, so a selector
  Service with that name makes the endpoints controller fight Patroni
  for the object — Patroni loses every CAS and logs only
  `Could not take out TTL lock`.
- Pods need the **`cluster-name: <scope>` label**. Patroni appends
  `scope_label` to its member selector but never stamps it; without it
  replicas can't discover the leader's `conn_url` and fail in ~1ms with
  a bare `failed to bootstrap from leader`.
- `podManagementPolicy: Parallel`. OrderedReady deadlocks when the
  initialized data lives on a higher ordinal.
- **Generated passwords must be newline-stripped.** Env carries a
  trailing `\n`, pgpass drops it — the role ends up with `password\n`
  while `pg_basebackup` sends `password`. Create secrets with
  `--from-literal="$(cat file)"`, not `--from-file`.
- **After any Patroni failover, flush the pooler**: pgbouncer's pooled
  connections stay pinned to the demoted primary. `RECONNECT` on the
  admin console — and do it **per pod IP**, because through the Service
  VIP you hit one pod at random (visible as OK/ERROR flapping).

## Where to read more

- `docs/notes/patroni.md` — how Patroni works, plus the 7.4 correction
- `docs/decisions/006-*` — why the k8s-API DCS and a custom image
- `docs/decisions/007-*` — the CNPG verdict and scoring
- `docs/journal/2026-07-{18,26,28,29,31}-*` — the sessions themselves,
  including every trap above at full length
