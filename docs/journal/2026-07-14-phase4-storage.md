# 2026-07-14 (evening) — Phase 4: storage, and a proper eBPF debugging story

## Part 1: local-path (portable)

Installed local-path-provisioner v0.0.36 as default StorageClass. A fresh
kubeadm cluster has NO StorageClass — a PVC just Pends, the storage version
of CoreDNS-without-CNI. Ran the journal-file exercise:

- `WaitForFirstConsumer` visible live: PVC stays Pending *by design* until a
  pod schedules, so the volume can be created on that pod's node.
- Data survives pod deletion; the replacement pod is *forced* to the same
  node by the PV's hard `nodeAffinity` pin.
- Forcing a pod to a different node with the same PVC → unschedulable, with
  a scheduler message that reads like a tour of the cluster: worker-1
  rejected (PV affinity), worker-2 rejected (nodeSelector), cp-1 rejected
  (control-plane taint). Node-local storage = scheduling constraint.

## IAM interlude

EBS CSI needs EC2 API credentials → node IAM role + instance profile
(`AmazonEBSCSIDriverPolicy`). PowerUserAccess can't create roles, so:
new Identity Center user `tkahng-admin` (admin group) → profile
`personal-admin`. Gotchas: the browser SSO session belongs to whoever logged
in last — an `aws sso login` for the poweruser profile approved by an
admin-user browser session mints a token that 403s ("No access") when asking
for the PowerUser role. And once instances carry an instance profile, every
future instance-touching `pulumi up` needs `iam:PassRole` → Pulumi (S3
backend and provider) moved to `personal-admin` permanently.

## Part 2: EBS CSI — the debugging story

Driver installed via Helm → **everything CrashLoopBackOff**. The chase:

1. Controller log: stuck at "Attempting to retrieve instance metadata from
   IMDS". Node plugin log: k8s fallback failed — "node providerID empty" —
   because only a CCM sets providerID and we deliberately run none
   (ADR 003 rhyming with reality). So IMDS *must* work from pods.
2. From a pod: token PUT times out. From the node: IMDS fine. Instance
   metadata options verified correct (IMDSv2 required, hop limit 2).
3. Checked Cilium's NAT rules (nft on Ubuntu 24.04 — `iptables` alone can't
   read them): pod→IMDS traffic IS masqueraded. Not NAT.
4. **Hubble ended the mystery in one command**: `hubble observe --ip
   169.254.169.254` → `TTL exceeded DROPPED` on every response data packet.
   Hop limit 2 is one too few with an overlay CNI: one hop into the node
   stack, one crossing Cilium into the pod veth. TCP *connected* (handshake
   packets survived) while every data packet died — hence the confusing
   "connects but never responds" symptom.
5. Fix: `HttpPutResponseHopLimit: 3` in Pulumi, rollout restart → all green.

Then the payoff demo: PVC on `ebs-sc` (gp3), writer pinned to worker-1,
reader pinned to worker-2 — the exact case that deadlocked local-path. EBS
detached/reattached across instances in ~30s, data intact. Bonus:
`Encrypted: true` on the volume, courtesy of the account-level default from
hardening day — zero cluster config.

## Takeaways

- The observability tooling installed in Phase 3 paid for itself in Phase 4.
  Logs said "timeout"; Hubble said *why* and *where*.
- Cloud addons pull cloud identity with them: one driver brought an IAM
  role, a PassRole requirement, and a permanent profile switch.
- local-path default + ebs-sc opt-in keeps the portability contract: every
  workload that doesn't say `storageClassName: ebs-sc` runs anywhere.
