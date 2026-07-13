# 2026-07-13 — Tooling, first Pulumi program, and the AWS pivot

## What happened

1. **Priced Hetzner properly and got surprised.** The June 15 2026 Hetzner
   price adjustment flipped the usual advice: ARM (CAX11 €5.99) is now *more*
   expensive than budget x86 (CX23 €5.49), and the CPX line more than doubled
   (CPX22 €7.99 → €19.49). Chose CX23. Lesson: re-verify pricing folklore;
   "ARM is the cheap option" had an expiry date. (ADR 001)
2. **Installed tooling** (pulumi v3.251.0, hcloud v1.66.0 via Homebrew; Go and
   kubectl were present), generated a dedicated cluster SSH key
   (`~/.ssh/hetzner_k8s`), wrote the Hetzner Pulumi program in Go, and got it
   compiling.
3. **Hetzner had no VM capacity** when it was time to provision. Created a new
   AWS account instead and made portability an explicit goal: the cluster must
   also deploy on-prem. (ADR 002)
4. **Restructured** into `infra/<provider>/` + provider-agnostic `cluster/`,
   defined the `nodes` inventory contract, wrote the AWS program (VPC, subnet,
   IGW, security group, 3× t3a.medium), both programs compile.

## Things learned

- **Pulumi supports any S3-compatible state backend** (we briefly planned
  Cloudflare R2 before settling on S3 once the AWS account existed).
- **Hetzner Cloud projects can't be created via API** — one manual console
  step, then everything else is automatable.
- **hcloud provider quirk:** resource IDs are strings but NetworkId/
  FirewallIds/PlacementGroupId want ints — hence the `intID()` helper.
- **Firewall semantics differ per cloud:** Hetzner firewalls only filter the
  public interface (private network traffic is unfiltered); AWS security
  groups filter *all* traffic, so node-to-node needs an explicit
  self-referencing rule. This is exactly the kind of difference the
  inventory-contract seam is meant to contain.
- **Login users differ per image:** Hetzner Ubuntu → `root`, AWS Ubuntu AMI →
  `ubuntu`. Encoded as `sshUser` in the contract instead of assuming.
- **AWS costs ~7× Hetzner for the same shape** (t3a.medium $27/mo vs CX23
  €5.49/mo), but new-account credits (~$200/6mo) plus hourly billing and a
  teardown habit make it effectively free for this project.

## Next session

- Set up personal-account AWS profile (credentials stay out of chat)
- Create S3 state bucket, `pulumi login`, `pulumi stack init`, set config
  (`myIp`, `sshPublicKey`), first `pulumi up`
- SSH into all three nodes → start the Phase 2 kubeadm runbook
