# 2026-07-15 — Phase 6, Drill 3: etcd backup → disaster → restore

The drill that matters before Phase 7 puts a real database in the cluster.
Proved with a time-travel experiment:

1. Created configmap `drill3-before-snapshot`
2. `etcdctl snapshot save` (23 MB, 1655 keys — the ENTIRE cluster state)
3. Created configmap `drill3-after-snapshot`
4. Disaster: stopped etcd + apiserver (moved static-pod manifests out),
   `mv /var/lib/etcd /var/lib/etcd-DESTROYED`
5. `etcdutl snapshot restore` into a fresh data dir (member flags must
   match the manifest: --name, --initial-cluster,
   --initial-advertise-peer-urls), manifests back, kubelet resurrects
   the control plane
6. **Verdict: before-marker alive, after-marker NotFound.** The restore
   rewinds everything to the snapshot instant; later writes are erased.

## Observed along the way

- **Control plane down ≠ outage**: with etcd AND the apiserver stopped,
  kubectl was refused while the hello app served HTTP 200. Running pods,
  ingress, and Cilium keep working without the API — you just can't
  *change* anything. (Third time this lesson has appeared; first time
  this starkly.)
- Static pods again: "stopping etcd" = moving a YAML file out of
  /etc/kubernetes/manifests; the kubelet notices and kills it. Moving it
  back is the restart. No systemd, no kubectl involved.
- Tooling: matched etcdutl/etcdctl (3.6.8) from the upstream release
  tarball; Ubuntu's etcd-client is older and snapshot-restore moved from
  etcdctl to etcdutl in 3.6.
- Snapshot needs etcd's client certs (server.crt/key + ca from
  /etc/kubernetes/pki/etcd) — the PKI directory from runbook 02 B2,
  now used in anger.

## Implications for Phase 7

- etcd snapshots capture Kubernetes OBJECTS, not PV contents — a
  Postgres PVC's data needs its own backup (volume snapshots / pg_dump /
  WAL archiving). etcd restore + missing volumes = pods pointing at
  ghosts.
- A restore rolls back EVERYTHING cluster-wide — on a shared cluster,
  restoring to fix one thing reverts everyone else's changes too.
- TODO(Phase 6+): schedule snapshots (cron on the cp or a CronJob) and
  ship them off-node (the drill's snapshot lives on the node it protects
  — fine for a drill, useless for a real node loss).

Dated snapshot kept at /root/etcd-snap-20260715.db on the cp.
Remaining drill: node replacement.
