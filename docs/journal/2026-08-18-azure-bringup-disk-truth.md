# 2026-08-18 — The Azure return: five failures, five permanent fixes

The ADR 011 bring-up (foundation from absolute zero → six apps
Synced/Healthy) took one evening and failed five different ways en route.
Every failure produced a fix that survives this era — which is the whole
argument for drilling rebuilds instead of babying clusters.

## 1 · Deterministic names: the teardown really was cheap

`make foundation` recreated everything ADR 010 deleted — and every name
came back identical (`sttrkk8sf92a7ab3`, `kv-trk-k8s-f92a7ab3`, the node
identity's full resource ID), because foundation.sh hashes them from the
subscription id. The committed stack config was valid before the resources
it references existed again. The one thing that could not come back was
the vault-wrapped `encryptedkey` — purge destroys key material; same key
*name* ≠ same key.

Gotcha worth its runbook line: `pulumi stack init` does NOT read the
`secretsprovider:` line from the config file. Without
`--secrets-provider=azurekeyvault://…` as a flag it silently falls back
to demanding a passphrase.

## 2 · The apt mirror lottery — you cannot probe a DNS pool

Fresh nodes, prep failed: `azure.archive.ubuntu.com` timed out on port 80
*from inside Azure* while the global archive answered 200 from the same
shell. First fix — probe the mirror, fall back if unreachable — failed
even better: the probe said "mirror ok" and apt timed out seconds later.
Two runs, two different dead IPs (52.252.75.106, 52.147.219.192): the
hostname is a DNS pool with dead members in rotation. A probe tests one
member; apt's next connection draws another.

Final fix in `prep-node.sh`: rewrite the cloud-local mirror to
`archive.ubuntu.com` unconditionally. Slower downloads, deterministic
bootstrap — and provider-neutral, since AWS pins
`<region>.ec2.archive.ubuntu.com` the same way.

## 3 · Dropped large writes — etcd on a disk with no latency SLA

Bootstrap then died twice at the same spot, once per attempt, both times
on Cilium's ~1MB helm release secret: first a POST timeout, then — with
the resources actually installed and nodes going Ready — a failed PUT
that left helm's ledger stuck at `pending-install`. Meanwhile small
writes committed in 0.3s and etcd logged **70 "apply request took too
long" warnings in 30 minutes**.

The StandardSSD OS disk was the trial-era economy choice, and StandardSSD
has *no latency SLA*. etcd fsyncs every write. Fixes, in layers:

- bootstrap's Cilium install got the same 3-attempt retry as
  platform.sh's `helm_i` (uninstall between attempts so a half-created
  release can't wedge it)
- the stuck `pending-install` release was repaired surgically: the status
  lives inside the secret as base64(gzip(json)) — decode, flip
  `info.status` to `deployed`, re-encode, patch. Leaving it would have
  blocked every future `helm upgrade cilium` with "another operation is
  in progress"
- the real fix: **Premium P6 (64 GB) on all three nodes** — cp-1 for
  etcd, workers because local-path PVs (the Postgres volumes) live on
  the OS disk. ~$10/mo each, `DeleteOption: Delete`, so it only bills
  while the cluster exists. Since the restart: **zero** slow-apply
  warnings.

## 4 · The disk conversion that kept the cluster

Pulumi previewed the disk change as an in-place `update`, but ARM refused
it through the VM resource (409 OperationNotAllowed — "update the disk
resource instead"). The working sequence:

    az vm deallocate ×3
    az disk update --sku Premium_LRS --size-gb 64   # per disk
    pulumi up        # reconciles; VM PATCH now matches reality
    az vm start ×3

The cluster *resumed* — no re-bootstrap, no data loss, same public IPs
(Standard/Static PIPs are separate resources that survive deallocation).
kubeadm, etcd, CNPG, ArgoCD all just woke up. This doubles as an
accidental drill: a full-cluster power-outage recovery, passed.

## 5 · NetBox's 26 OOM-kills — the cgroup shoots a healthy app

NetBox's web pod had crash-looped since platform ran: **OOMKilled 26
times, ~48s after each start**, serving 200s right up to the bullet. Four
gunicorn workers warming caches spike past the 1Gi limit before settling
near 250Mi idle. Same ceiling the AWS era grazed from the other side
(debug shells sharing the cgroup, 08-07 journal). Limit → 2Gi, via git —
ArgoCD owns the app, so kubectl was never an option.

The tell that it wasn't a code or config failure: `Last State:
OOMKilled` in describe, plus perfectly normal access logs. A crash-loop
where the logs look healthy is a resource kill until proven otherwise.

## State

Six apps Synced/Healthy on Premium disks, CNPG 2/2, WAL flowing to blob.
Remaining: Cloudflare A record → 20.127.42.91, then populate.sh — the
first fresh-cluster test of the v2 token self-heal. Teardown deadline:
**Sept 4** (credits expire; no spending limit behind them).
