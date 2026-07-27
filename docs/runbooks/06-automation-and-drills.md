# Runbook 06 — Automation and drills

Phase 6: the manual runbooks become scripts, then we drill until rebuilds
are boring. "Cattle, not pets" is only true if you've actually shot a cow
and had dinner on time.

## The scripts (all consume the inventory contract — provider-agnostic)

| Script | Encodes | Runs |
|---|---|---|
| `cluster/prep-node.sh` | runbook 02 Part A | on each node (pushed by bootstrap) |
| `cluster/bootstrap.sh` | runbook 02 B+C+D + runbook 03 | laptop |
| `cluster/platform.sh`  | runbooks 04 + 05 | laptop |

Make targets: `make bootstrap`, `make platform`, and the whole drill:
`make rebuild` (destroy → up → bootstrap → platform).

All scripts are idempotent — re-running against a live cluster skips
what's done (prep re-runs harmlessly; init/join/helm installs are guarded).

Secrets are file-driven, never in git:
- Cloudflare token: `~/.config/trk-k8s/cloudflare-token` (chmod 600)
- ArgoCD deploy key: `~/.ssh/argocd_trk_k8s`

## Resuming a session after `make destroy`

The between-sessions habit is teardown, so "pick up where I left off" is:

    make up         # machines exist (check-ip preflight runs automatically)
    make bootstrap  # machines become a cluster
    make platform   # cluster becomes useful; ArgoCD pulls the apps back

NOT `make rebuild` — that starts with a destroy, which is for blowing away
a *running* cluster, not resuming a dead one. Each step is idempotent:
if one fails partway (transient apiserver reset, SSH race), re-run it.

Two things to keep in mind when resuming:

- **The cluster restores to what GIT says, not where your session left
  off.** Uncommitted manifests, unpushed branches, and anything mid-phase
  in the working tree are invisible to ArgoCD. Resuming mid-phase means
  the cluster comes back at the last *pushed* state — usually what you
  want, occasionally a surprise.
- **PV data died with the machines** (local-path = node disk; drill 3:
  etcd snapshots don't cover it either). Anything stateful restarts
  empty until the Postgres backup story lands (Phase 7).

Then the post-rebuild manual steps below.

## Post-rebuild manual steps (DNS is outside the cluster)

1. Cloudflare: update `*.k8s.kahng.dev` A record → new control-plane
   public IP (proxy off).
2. `apps/hello/overlays/dev/ingress-host.yaml`: new nip.io host if used;
   commit + push (ArgoCD owns the app — git is the only way to change it).
3. New ArgoCD admin password (initial secret) if you use the UI.

Let's Encrypt note: a fresh cluster re-issues certs (the old secret died
with the cluster). Prod rate limit is 50/week per domain — a few rebuilds
are fine; heavy drill days should switch the annotation to
`letsencrypt-staging`.

## Drills

### Drill 1 — teardown → rebuild (the foundational one)
`make rebuild`, stopwatch running. Success: `kubectl get nodes` Ready ×3,
hello app Synced/Healthy in ArgoCD, HTTPS green after the DNS update.
Record the time in the journal. Target: coffee-break territory.

### Drill 2 — kubeadm upgrade (planned)
v1.35 → v1.36, control plane first, then workers one at a time with
drain/uncordon. The reason nodes install a pinned minor and apt-mark hold.

### Drill 3 — etcd backup/restore (planned)
`etcdctl snapshot save` on the control plane; restore into a fresh init.
The difference between rebuilding the cluster and losing its state.

### Drill 4 — node replacement (planned)
Terminate a worker in AWS, watch pods reschedule, join a replacement.

### Stretch
HA control plane (3 CPs behind an LB); same cluster on Hetzner via
`infra/hetzner` — the portability proof.
