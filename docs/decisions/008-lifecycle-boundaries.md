# ADR 008 — Lifecycle boundaries: a persistent data stack, and GitOps-managed Applications

Date: 2026-08-01. Status: accepted, implemented (pre-7.5).

## Context

Two known defects blocked the Phase 7.5 capstone and all of Phase 8.
Both were recorded as consequences in ADR 007; both are about something
being managed at the wrong lifecycle.

1. **The backup bucket died with the cluster.** The 7.4 backup lab put
   `trk-k8s-pg-backups` in the same Pulumi stack as the EC2 nodes, with
   `ForceDestroy: true`. So `make destroy` — the between-sessions habit
   since Phase 1 — reaped the backups it had just taken. Harmless within
   one session, and fatal to the thing backups are *for*: restoring into
   a cluster that didn't exist when the backup was made. Phase 8's
   rebuild-with-state drill is exactly that.
2. **ArgoCD Applications were not GitOps-managed.** `platform.sh` applied
   `cluster/gitops/*.yaml` imperatively, once, and nothing watched them
   afterwards. During the 7.4 bring-up a fix was committed, pushed, and
   changed nothing — twenty minutes lost before applying it by hand,
   which is the precise indignity GitOps exists to remove.

## Decision

### 1. Data that outlives the cluster gets its own stack

New Pulumi project `infra/aws-persistent` (stack `prod`) owning the
backup bucket and a customer-managed IAM policy for it. `make destroy`
and `make rebuild` touch only `infra/aws`.

- **No `ForceDestroy`.** A `pulumi destroy` on the persistent stack must
  *fail* on a non-empty bucket. Emptying it is a deliberate act, never a
  side effect of a teardown.
- **Versioning on**, plus lifecycle rules to abort incomplete multipart
  uploads (7d) and expire noncurrent versions (30d) — barman prunes what
  it knows about; this is the janitor for what it doesn't.
- **One string crosses the seam**: the ephemeral stack reads
  `pg-backup-policy-arn` via `StackReference` and attaches it to the node
  role it owns. The bucket name is re-exported as a passthrough so
  `pulumi stack output` still answers "where do backups go".
- `make persist-up` creates it; `make persist-destroy` exists but demands
  a typed confirmation and explains that it deletes every backup.

Rejected alternatives: `RetainOnDelete` orphans the bucket out of state,
so the next `up` collides with the existing bucket and needs an import
dance. `Protect` makes `pulumi destroy` fail outright, breaking the
teardown habit rather than modelling it. Creating the bucket by hand
(the precedent set by the Pulumi *state* bucket) works but leaves it
undescribed in code.

**The general rule: a lifecycle boundary is a stack boundary.** If two
resources have different answers to "when is it correct to delete
this?", they do not belong in the same stack.

### 2. App-of-apps: one imperative apply, ever

`cluster/gitops/root.yaml` is the only Application `platform.sh` applies.
It watches `cluster/gitops/apps/`, where the four (soon five) child
Applications now live. Adding a file creates an Application; editing a
`syncPolicy` takes effect on push.

Root deliberately does **not** watch its own directory. A self-managing
root works, but if root's own spec breaks, the only repair is a hand
apply — which is where we started.

## Consequences

- **Deleting a file from `cluster/gitops/apps/` deletes that Application
  and, by cascade, everything it deployed.** `prune: true` on root is the
  intended power and the obvious footgun: removing
  `apps/postgres-cnpg.yaml` would take the database with it.
- The root carries the same `retry` block as the CNPG child, because the
  operator's CRDs must exist before `postgres-cnpg` can sync — ordering
  by convergence, not by sequencing (the 7.4 part 1 lesson).
- `make persist-up` is a new one-time prerequisite before any cluster can
  archive WAL: the ephemeral stack's `StackReference` fails if the
  persistent stack doesn't exist yet.
- Bucket contents now survive every teardown, so **backup storage costs
  are continuous** rather than per-session. Small (WAL + a 4 MB base
  backup, 7-day retention) but no longer zero when the lab is idle.
- The node-scoped credential caveat from ADR 007 is unchanged: any pod on
  the node can reach the bucket via IMDS. IRSA still wants an OIDC
  provider kubeadm doesn't create.
- Phase 8's premise is now actually testable: destroy everything, rebuild
  on different machines (or a different OS), restore real data from a
  bucket that was never part of what died.
