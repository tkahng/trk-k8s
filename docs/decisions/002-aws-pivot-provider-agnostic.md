# ADR 002: Pivot to AWS; keep the cluster provider-agnostic

Date: 2026-07-13
Status: accepted (supersedes the Hetzner-specific parts of ADR 001)

## Context

Hetzner had no VM capacity available when we were ready to provision, so a new
AWS account (785464635442) was created. Beyond the immediate blocker, the goal
is now explicitly: **the cluster must be deployable on any provider, including
on-prem hardware**, with as little provider-specific surface as possible.

## Decision

Two-layer architecture with a hard seam:

1. **`infra/<provider>/`** — one Pulumi Go program per provider (aws, hetzner,
   more later). Provider-specific by nature, but every program exports the same
   `nodes` inventory contract (name, role, publicIp, privateIp, sshUser) and
   implements the same address plan (nodes at 10.0.1.10-12 in 10.0.1.0/24).
2. **`cluster/`** — everything from "3 Ubuntu machines with SSH" to "working
   Kubernetes". Consumes only the inventory. For on-prem, the inventory is
   written by hand and layer 1 is skipped entirely.

Cloud integrations (cloud-controller-manager, CSI drivers, cloud LBs) are
**optional addons per environment**, never part of the core cluster. Portable
defaults are preferred: NodePort/ingress over `type=LoadBalancer`, and later
MetalLB (on-prem) or local-path/Longhorn for storage.

AWS specifics (see pricing research in the session journal):
- **t3a.medium** (2 vCPU, 4 GB, $0.0376/hr) in **us-east-1** — same shape as
  the CX23 plan; the new account's ~$200/6-month credits cover the project if
  we keep the teardown habit (~$0.35 per 3-hour lab session; ~$82/mo if left
  running).
- Pulumi state moves from the planned Cloudflare R2 to an **S3 bucket** in the
  same account (one credential setup).

## Consequences

- The Hetzner program stays in `infra/hetzner/` — when they have capacity
  again, the same cluster can be stood up there as a portability proof.
- One real difference surfaced immediately and is worth remembering: Hetzner
  firewalls only filter the public interface (private network traffic flows
  freely), while AWS security groups filter everything — node-to-node traffic
  needs an explicit self-referencing allow rule.
- kubeadm's Phase 2 runbook must avoid provider assumptions (e.g. login user is
  `root` on Hetzner but `ubuntu` on AWS — hence `sshUser` in the contract).
