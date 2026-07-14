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

## New-account hardening (done this session)

Identity: IAM Identity Center (no long-lived keys) — `tkahng-poweruser` with
PowerUserAccess, local profile `personal` via `aws configure sso`. Lessons:
Identity Center users sign in at the access portal URL (`*.awsapps.com/start`),
NOT the normal AWS sign-in page — the wrong door gives a misleading
"authentication failed". PowerUserAccess cannot call `iam:*`/`account:*` APIs
(root MFA and alternate contacts must be checked in the console as root).

Account defaults audit → applied:
- ✅ already existed: "My Zero-Spend Budget" ($1, from signup wizard) — fires
  when real cash is owed (net of credits); CloudTrail 90-day event history
  (default, free — no persistent trail on purpose)
- 🔧 applied: account-wide S3 Block Public Access (all four flags); default
  EBS encryption in us-east-1
- ⏳ deferred: cost-allocation tag activation for `cluster` (only possible
  ~24h after tagged resources exist); optional gross-usage budget to watch
  credit burn
- Pulumi state: versioned S3 bucket `tkahng-pulumi-state`, backend
  `s3://tkahng-pulumi-state?region=us-east-1&profile=personal`

## First `pulumi up` — the cluster machines exist

Stack `dev` (project `trk-k8s-aws`), config: `aws:region`, `aws:profile`,
`myIp` (admin CIDR), `sshPublicKey` (new dedicated key `~/.ssh/aws_k8s`).
Secrets passphrase lives in `~/.config/pulumi/trk-k8s.passphrase` (chmod 600,
random, never displayed — commands use `PULUMI_CONFIG_PASSPHRASE_FILE`).

First `up`: 10 of 11 resources created, then **`PendingVerification`** on the
third instance — brand-new AWS accounts get their first launches in a region
manually validated (minutes to 4h). Lesson in how Pulumi handles partial
failure: state recorded the 10 successes, the retry created only the missing
instance. Second `up` a minute later: clean.

Verified: SSH to all 3 nodes as `ubuntu` with the new key; x86_64, 3.8 GiB RAM
each; private IPs 10.0.1.10-12 as planned; cp-1 can ping both workers over the
private network (the SG self-rule works).

Also learned: `aws configure sso` can't run through Claude Code's `!` prefix
(no TTY) — interactive AWS CLI wizards need a real terminal.

## Next session (Phase 2)

- Write and follow the kubeadm runbook: containerd + kubelet on all nodes,
  `kubeadm init` on cp-1 (advertise 10.0.1.10), join workers, kubeconfig to
  laptop
- Remember: `pulumi destroy` when not actively using the cluster
  (~$0.11/hr compute + ~$0.007/hr EBS while it exists)
- In ~24h: activate the `cluster` cost-allocation tag in billing
