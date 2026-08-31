# ADR 012 — The Talos verdict: kubeadm taught, Talos operates

Date: 2026-08-31. Status: accepted. Settles the judgment ADR 004 deferred.

## Context

ADR 004 (July) deferred Talos until "the machinery had been seen" — until
kubeadm's certs, static pods, etcd, joins, upgrades and drills had been
done by hand and then automated. Phase 8 ran the comparison the hard way:
the same three-machine topology, same address plan, same Cilium, same
CNPG-plus-plugin stack, on Talos — ending with the NetBox database
restored from the archive the final kubeadm cluster wrote.

## What the comparison measured

**The seam.** The provider-agnostic claim survives a cloud swap completely
(three times proven) and a distribution swap only partly. `cluster/` was
replaced wholesale, as predicted; `infra/` was NOT unchanged, falsifying
PLAN.md's prediction — image pipeline, ceremonial osProfile, port 50000,
and `sshUser` demoted to a carried lie. The parts of infra that describe
*what a machine is* belong to the OS, not the cloud.

**What Talos deleted** (each item a real historical failure here):
prep-node.sh entirely — the apt-mirror lottery that cost two bring-ups
cannot recur because there is no apt; the SSH-readiness race, because
there is no SSH; swap/sysctl/containerd setup, baked into the image.
KubePrism deleted the one provider-specific wart in the Cilium install.
Failures moved from bring-up time (random) to image/config time
(deterministic, better error messages).

**What Talos charged** (each also real): an image pipeline Azure gives
Ubuntu for free, plus the SCSI/NVMe gallery bridge; three days of
bootstrap failures with three DIFFERENT causes behind one timeout symptom
— cert SANs, admin-IP flip-flop, and talosctl's fixed dial deadline
(resolved only by running talosctl inside the VNet); cluster-wide PSS
enforcement colliding with hostPath storage; and a pinned Kubernetes
version (v1.36.2 vs kubeadm's v1.36.4 — the bundle is the bundle).

**What was identical**: Cilium values minus five Talos-specific keys, the
CNPG stack byte-for-byte, the object-store archive format, the address
plan, and the data.

## Decision

- **kubeadm+Ubuntu remains this project's primary platform.** The
  project's purpose is legibility — seeing the machinery — and kubeadm
  exposes exactly the surfaces Talos deliberately seals. Every drill on
  the card depended on that visibility at least once.
- **Talos is the answer to a different question**: not "how does
  Kubernetes work?" but "how do I stop operating Ubuntu?" For a fleet
  someone must keep patched, SSH'd, and mirror-fed, Talos deletes entire
  failure classes this project paid for individually. If this cluster
  ever becomes a thing that must simply STAY UP rather than teach,
  Talos is the migration target, and runbook 08 plus `cluster-talos/`
  is the working starting point.
- The Talos lab stays in-repo as reference (`infra/azure-talos`,
  `cluster-talos/`, runbook 08), same policy as parked providers.

## The one-line verdict

kubeadm shows you Kubernetes; Talos hides Linux. After eight phases of
wanting to see everything, hiding Linux is finally recognizable as a
feature — just not the one this project was built to want.
