# ADR 003: No cloud-controller-manager in the core bootstrap

Date: 2026-07-13
Status: accepted

## Context

CCM connects a cluster to a specific cloud: node controller (providerID,
addresses, dead-instance cleanup), service controller (`type=LoadBalancer` →
real cloud LB), route controller. The catch: it must be decided at bootstrap
time — a kubelet started with `--cloud-provider=external` registers its node
with an `uninitialized` taint that only a running CCM removes, and a node
registered *without* the flag can't reliably be adopted by a CCM later
(providerID/taint handshake never happened). Hence the folklore "CCM must be
set up before bootstrapping."

Also AWS-specific: the AWS CCM expects node names to match the EC2 private
DNS name (e.g. `ip-10-0-1-10.ec2.internal`), constraining kubeadm node naming.

## Decision

The portable Phase 2 runbook bootstraps with **no cloud provider at all**
(the modern default — in-tree providers are gone). Consequences accepted:
`type=LoadBalancer` stays pending, EC2-deleted nodes linger as NotReady.
This keeps one runbook valid for AWS, Hetzner, and on-prem (on-prem has no
CCM to clear the taint, so `--cloud-provider=external` could never be in the
shared path).

CCM becomes a **Phase 4 lab performed as a rebuild**: destroy → re-bootstrap
with `--cloud-provider=external` + aws-cloud-controller-manager → watch a
LoadBalancer Service provision an NLB → destroy. Rebuilds are cheap by then
(Phase 6 automation), and the lab teaches the taint/initialization handshake
explicitly.

Note: EBS CSI (Phase 4 storage) does not require CCM — it reads instance
metadata directly — so persistent volumes are unaffected by this decision.
