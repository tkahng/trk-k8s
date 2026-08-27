# 2026-08-27 — Drill 5: the cluster is cattle, the data is not

The last drill on the capstone card, and the one the whole phase was
arguing toward: destroy everything, rebuild from git, and have the
application come back **already holding its data** — not rediscovering
it, not re-seeded by hand, but recovered from object storage into a
database born minutes earlier on machines that did not exist.

It worked. It also took three attempts, and the two failures were both
in the measuring instrument rather than the thing being measured.

## The numbers (attempt 3, the real one)

| stage | duration |
|---|---|
| `make up` — 14 Azure resources from nothing | 88s |
| `make bootstrap` — prep ×3, kubeadm init, 2 joins, Cilium | 140s |
| `make platform` — CSI, cert-manager, gateway, secrets, ArgoCD | ~142s |
| convergence — 6 apps Synced/Healthy + archiving green | 141s |
| **total, destroy to fully converged** | **~8.5 min** |
| manual steps | **1** (Cloudflare A record) |

Cilium installed first try — the gateway-CRD retry added hours earlier
(after attempt 1 died there on `http2: client connection lost`) did its
job on its first real outing.

## The result that matters

`populate.sh` — which creates any object it can't find — created
**nothing** except the three new public IPs:

    ### sites and cluster            (silent)
    ### prefixes                     (silent)
    ### virtual machines             (silent)
      + ipam/ip-addresses 4.227.209.98/32
      + ipam/ip-addresses 20.127.23.182/32
      + ipam/ip-addresses 20.121.32.107/32

Site, cluster, all four prefixes, all three VMs, their interfaces and
private IPs: already there, recovered from `pg-20260827` (base backup
`20260827T194617` + all WAL, no recoveryTarget) into a cluster created
by ArgoCD from git during `make platform`.

A quieter proof hides in what did NOT print: no "token not accepted —
minting v2 token via the ORM". The API token in `~/.config/trk-k8s`
still matched the token row restored with the database. Two independent
survival paths — laptop file and object storage — agreeing across a
total infrastructure loss.

The honest residue: the previous era's public IPs (52.188.4.21 and
friends) are still in there as stale records, now 9 IPs for 3 machines.
That is what restored data meeting rebuilt infrastructure actually looks
like. Reconciling them is an IPAM problem, not a Kubernetes one.

## The staging that made it possible (bootstrap is immutable)

`bootstrap.recovery` applies ONLY at cluster creation, so it had to be
in git before `platform.sh` ran — attempt 1 got this backwards and the
cluster came up empty and unrecoverable-into. Staging it while the old
cluster still lived exposed a trap worth recording:

pushing the new generation's config made the LIVE cluster adopt the new
`serverName`, and with `archive_timeout = 5min` it began dribbling WAL
into the very prefix the rebuild needed pristine. Fix: point the dying
cluster back at its own prefix — which required pausing the **root**
app-of-apps first, because patching the child Application was reverted
within seconds by root's selfHeal. In app-of-apps, a child's spec is
root's data.

## Three attempts, three instrument failures

1. **The harness measured a no-op and reported numbers.** `make up`
   said "14 unchanged", bootstrap said "already initialized" — the
   rebuild had happened by hand beforehand. A measurement harness that
   cannot detect its own precondition produces confident nonsense; it
   now refuses to start unless the stack is empty.
2. **The harness died before printing its own scorecard.** `populate.sh`
   exited non-zero, `set -e` did the rest, every measurement lost. A
   failed stage is now recorded and the run continues.
3. **The harness blocked on stdin that wasn't there.** Backgrounded, the
   manual-step `read` hit EOF and killed the script one step from the
   finish line — after a perfectly good rebuild. Now reads `/dev/tty`,
   and polls DNS when there's no terminal at all.

Worth stating plainly: the instrument failed three times and the system
under test failed zero times. Attempt 3's cluster came up clean on every
stage. The drills have been teaching this all week — drill 2's outage
was our config, drill 3's inverted both predictions, drill 4's blocker
was a silent archiving refusal — and the pattern holds. Infrastructure
is rarely the unreliable part; the things we build to observe and
deploy it are.

## Card complete

1. Failover under load — 31s write gap, pooler absorbed it, zero loss
2. Migrations at scale — migration innocent, delivery machinery guilty
3. Cache vs queue — both textbook predictions inverted
4. Restore with the app attached — deleted machine back in the UI
5. **Rebuild from git + blob — 8.5 minutes, 1 manual step, data intact**

Phase 8's premise — rebuild with real data at stake — is no longer a
premise.
