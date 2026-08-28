# 2026-08-28 — Phase 8, Session A: Talos onto Azure, and a falsified prediction

Session A's goal was narrow: get three Talos machines running on Azure and
a Kubernetes control plane bootstrapped on them. It is **not finished** —
`talosctl bootstrap` timed out, the cause was found and fixed, and the
re-run has not happened yet. What follows is what the attempt has already
taught, recorded now rather than after the fact.

## The prediction PLAN.md got wrong

Phase 8 was written with this claim: *"Not a provider swap —
`infra/<provider>/` survives unchanged."* The reasoning was that Talos
changes the OS, so `cluster/` gets replaced while the machine-provisioning
layer stays put. Half right. `cluster/` **is** entirely replaced. But
`infra/` needed four changes, none optional:

1. **The image.** Azure has no Talos marketplace or community-gallery
   image (the release's own `cloud-images.json` has zero Azure entries),
   and the GitHub release ships no Azure asset — image generation moved to
   the **Image Factory**. So: fetch a VHD, upload as a page blob, build an
   image. A whole script (`infra/azure-talos/image.sh`) that Ubuntu got for
   free from one `ImageReference` block.
2. **An `osProfile` for an OS with no users.** Azure refuses to create a VM
   from a generalized image without one: *"Required parameter 'osProfile'
   is missing (null)"*. Talos has no `/etc/passwd`, no password auth and no
   sshd — yet the request must carry an admin username and a public key,
   which are written to an `authorized_keys` file that will never exist.
   Azure validates the REQUEST, not the image.
3. **Port 50000 instead of 22.** The whole "no SSH" difference, expressed
   as one NSG rule.
4. **`sshUser` became a lie.** The inventory contract carries it for every
   provider; on Talos it is `"n/a-talos"` and every consumer must ignore
   it. Kept rather than dropped, because a second contract shape is how
   seams die — but it is a wart, not a win.

**Revised claim:** the seam absorbs a *cloud* swap completely (proven three
times) and a *distribution* swap only partially. The parts of `infra/`
that describe **what a machine is** — image, identity, credentials — turn
out to belong to the OS, not the cloud.

## The NVMe wall (a genuinely modern problem)

The first VM creation failed with *"cannot boot with OS image or disk ...
check disk controller types"*. Cause: a managed image built from a VHD is
**SCSI-only**, and every VM family this subscription has quota for
(`D*_v7`) is **NVMe-only**. The two cannot meet.

Searching for a SCSI-capable size that is both unrestricted in eastus and
has quota returned exactly nine SKUs — all confidential-compute (DC/EC) or
GPU (NV) families, **every one of them at zero quota**. So there is no
"pick an older size" escape hatch here.

The bridge is an **Azure Compute Gallery**: a managed image cannot declare
what disk controllers it supports, but a gallery *image definition* can,
via `--features "DiskControllerTypes=SCSI,NVMe"`. So `image.sh` now
publishes the managed image into a gallery, and the VMs reference the
gallery version. A 2018-shaped disk image meeting 2026-shaped hardware,
with the gallery as the adapter.

## The bootstrap timeout: a Phase 2 lesson in new clothes

Steps 0–3 ran perfectly — API reachable on all three nodes, machine
configs generated, configs applied. Then `talosctl bootstrap` retried for
ten minutes and gave up with no useful error.

Cause: **certificate SANs**. Azure public IPs are NAT — a node never sees
its public address on its own NIC — so nothing puts that address in the
API certificates, and every non-insecure call from the laptop fails TLS.
This is precisely the problem kubeadm solved in Phase 2 with
`--apiserver-cert-extra-sans`, arriving again in a different accent.

Fix: `talosctl gen config --additional-sans <every public IP>`, plus
automatic regeneration whenever the current control-plane public IP is
missing from the existing config — because a rebuild reassigns public IPs,
and stale certs fail in a way that never names its cause.

Worth noticing: **both of Session A's fixes were ported instincts.** The
cert-SAN problem and the admin-IP drift guard were solved once on kubeadm,
forgotten, and re-earned on Talos. Experience transferred, but only after
the same ten-minute timeout.

## What Talos deleted

Set against those costs, the other column. `cluster-talos/bootstrap.sh`
has no equivalent of:

- hostname setting, swap checks, kernel modules, sysctls
- containerd installation
- **apt at all** — which on Ubuntu cost this project two failed bring-ups
  to a mirror DNS pool with dead members in rotation
- an SSH-readiness race

All of it is baked into an immutable image. The trade is stark and now
concrete: Talos moves work from *bring-up time* (where it fails randomly)
to *image and config time* (where it fails deterministically, usually with
a clearer error — the NVMe refusal named its own cause; the apt mirror
never did).

## State

Session A is **incomplete**. Fixed and committed: the image pipeline, the
osProfile requirement, the gallery/NVMe bridge, the cert SANs. Not yet
done: a successful `talosctl bootstrap`, so no Kubernetes control plane
exists on Talos yet. Next run is `make talos-up && make talos-bootstrap`,
expected to end with three NotReady nodes (`cni: none` is deliberate —
Cilium is Session B).

No runbook yet, on purpose: this project does not write a runbook for a
procedure it has not completed once.
