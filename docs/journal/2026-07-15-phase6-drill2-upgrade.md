# 2026-07-15 — Phase 6, Drill 2: rolling upgrade v1.35.6 → v1.36.2

Full rolling upgrade with zero downtime — the hello app returned HTTP 200
at every checkpoint, including while etcd and the API server were being
swapped underneath it. Data plane ≠ control plane, experienced live.

## The choreography (why the order matters)

1. **kubeadm binary first** (repo swap to the v1.36 stream, unhold →
   install → hold). The tool upgrades before the cluster.
2. **`kubeadm upgrade plan`** — preflight showing exactly what would
   change (all components 1.35.6→1.36.2, etcd 3.6.6→3.6.8, CoreDNS bump,
   no manual config migrations).
3. **`kubeadm upgrade apply v1.36.2`** on the cp — swaps static-pod
   manifests one component at a time, backing up old manifests.
4. **cp kubelet**: drain → install → restart → uncordon.
5. **Each worker**: drain (watch pods migrate) → repo swap →
   `kubeadm upgrade node` (just refreshes kubelet config; workers have no
   control plane) → kubelet → uncordon. tkahng drove worker-1 by hand;
   worker-2 scripted.

## Incidents (the honest part)

- **SSH died mid-upgrade and took kubeadm with it** — connection reset
  exactly at the etcd swap (peak memory pressure on a 4GB node). The
  upgrade process was a child of the SSH session. Recovery: the kubelet
  had already finished the etcd swap from the new manifest; re-running
  `kubeadm upgrade apply` under **nohup** completed idempotently.
  LESSON: long remote operations run under nohup/tmux, never naked in a
  session. (Second occurrence of "the drill found the bug": drill 1
  found the SSH race, drill 2 found the session-lifetime mistake.)
- **Transient `Forbidden` right after kubelet restart** — the API server
  was still warming up (RBAC not yet synced). Retry succeeded. Not every
  error is real; some are just "too early".

## Learned

- Mixed-version clusters (cp 1.36 / workers 1.35) are a supported,
  normal mid-upgrade state — version-skew tolerance is what makes
  rolling upgrades possible at all.
- `kubeadm upgrade apply` is resumable/idempotent — designed for exactly
  the interruption we caused.
- Drain evicts pods but not DaemonSets (hence --ignore-daemonsets) —
  Cilium/CSI pods stay put by design.
- prep-node.sh bumped to v1.36 so rebuilds don't downgrade; the upgrade
  lab re-arms when v1.37 ships.

Remaining drills: etcd backup/restore (before Phase 7 puts real state in
the cluster), node replacement.
