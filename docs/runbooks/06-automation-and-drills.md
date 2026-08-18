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

**Two stacks, two lifecycles (ADR 008).** `infra/aws` holds the machines
and is destroyed every session. `infra/aws-persistent` holds the Postgres
backup bucket and is created ONCE (`make persist-up`) and never destroyed
by a lab cycle — a backup that dies with the cluster isn't one. The
ephemeral stack reads one value from it (the IAM policy ARN) via
StackReference, so `make up` FAILS until `make persist-up` has run.

**ArgoCD Applications are GitOps-managed (ADR 008).** platform.sh applies
only `cluster/gitops/root.yaml`; that root watches
`cluster/gitops/apps/` and creates the children from git. Editing an
Application's spec now takes effect on push — before this, it silently
did nothing. Beware `prune`: deleting a file from `apps/` deletes that
Application and cascades to everything it deployed.

All scripts are idempotent — re-running against a live cluster skips
what's done (prep re-runs harmlessly; init/join/helm installs are guarded).

Secrets are file-driven, never in git:
- Cloudflare token: `~/.config/trk-k8s/cloudflare-token` (chmod 600)
- ArgoCD deploy key: `~/.ssh/argocd_trk_k8s`

## Resuming a session after `make destroy`

The between-sessions habit is teardown, so "pick up where I left off" is
the durable half first (once per provider era, idempotent), then the
three-step bring-up:

    # durable half, if it doesn't exist yet — provider-specific:
    #   AWS:   make persist-up   (backup bucket + IAM policy, ADR 008)
    #   Azure: make foundation   (locked RG: state, vault, SP, identity)
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

## Switching cloud providers (done three times: ADR 009, 010, 011)

The seam holds: `cluster/` has never changed during a swap. Everything
that DOES change is this checklist, in order:

1. **Repo rewire** — three files, all recoverable from git history
   (`git log --oneline -- Makefile` finds the swap commits):
   - `Makefile`: restore the target provider's header (INFRA_DIR,
     SSH_KEY, PULUMI wrapper, login/foundation-or-persist targets)
   - `cluster/platform.sh` provider: the Makefile's `platform:` target
     passes `--provider=aws|azure`
   - `apps/postgres-cnpg/base/cluster.yaml`: swap `barmanObjectStore`
     (S3 + `inheritFromIAMRole` ⇄ blob URL + `inheritFromAzureAD`)
2. **Durable half** — AWS: `make persist-up`; Azure: `make foundation`.
   Both idempotent.
3. **Pulumi state** — two cases:
   - state survived (AWS park keeps its S3 backend): nothing to do;
     `make preview` should show a clean N-to-create
   - state was deleted (every Azure exit deletes it — $0 requires it):
     remove the stale `encryptedkey:` from `Pulumi.dev.yaml` (the purged
     vault key can never unwrap it) and run
     `cd infra/azure && ./pulumi.sh stack init dev
     --secrets-provider="azurekeyvault://kv-trk-k8s-<suffix>.vault.azure.net/keys/pulumi-secrets"`
     — the flag is REQUIRED: `stack init` does not read the
     `secretsprovider:` line from the config file, and without the flag
     it falls back to demanding a passphrase. Everything else in the
     committed config stays valid because foundation.sh derives names
     from a hash of the subscription id — same subscription, same
     names, same resource IDs (ADR 011)
4. **Bring-up** — `make up && make bootstrap && make platform`, exactly
   the resume flow above
5. **DNS** — Cloudflare A record to the new control-plane IP (proxy off)
6. **Data** — `apps/netbox/populate.sh` re-records the NEW provider's
   reality (discovery-driven by design); CNPG starts a fresh WAL history
   against the new object store
7. **The provider you left** — park it (AWS: keep the buckets, pennies)
   or zero it (Azure: the full ADR 010 teardown — lock off, RG delete,
   vault PURGE, SP + orphaned role assignments, local env files).
   Which one depends on what idle costs there: S3 parks at pennies;
   an Azure storage account + vault bills forever.

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
