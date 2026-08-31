# Runbook 08 — Talos: provision, bootstrap, operate

Written 2026-08-31, immediately after the procedure completed once —
this project's bar for a runbook. Covers the Azure Talos cluster
(`infra/azure-talos`, `cluster-talos/`). The kubeadm equivalents this
replaces: runbook 02 (all of it) and the prep half of runbook 06.

## The flow

    make talos-image      # ONCE per Talos version (idempotent)
    make talos-up         # machines, cordless: no ssh key is ever used
    make talos-bootstrap  # configs + etcd + kubeconfig
    # end state: THREE NotReady NODES. Correct — cni: none by design.

    export KUBECONFIG=$PWD/kubeconfig-talos     # kubectl / k9s
    export TALOSCONFIG=~/.config/trk-k8s/talos/talosconfig
    make talos-dashboard  # the closest thing to ssh-ing into a node

    make talos-destroy    # gallery image + machine configs survive

## What there is NO equivalent of

- **prep-node.sh**: no hostname/swap/sysctls/containerd/apt. The image is
  the configuration. The apt-mirror lottery that cost two Ubuntu
  bring-ups cannot happen — there is no apt.
- **SSH**: no daemon, no shell, no `talos-ssh` target on purpose. The
  API on :50000 is the only door; `talosctl dashboard`, `talosctl logs`,
  `talosctl dmesg` replace "ssh in and look".
- **kubeadm init/join**: machine configs + one `talosctl bootstrap` RPC.

## Gotchas (each one cost a failed bring-up)

1. **Azure has no Talos image.** No marketplace, no community gallery,
   no release asset — the Image Factory is the source. `image.sh` does
   VHD → page blob → managed image → **Compute Gallery** version.
2. **The gallery is not optional.** A managed image from a VHD is
   SCSI-only; every VM family with quota here (D*_v7) is NVMe-only.
   Only a gallery image definition can declare
   `DiskControllerTypes=SCSI,NVMe`. Error if skipped: "cannot boot with
   OS image or disk".
3. **Azure demands an osProfile for an OS with no users.** A generalized
   image refuses to boot a VM without adminUsername + SSH key — Talos
   reads neither. Ceremonial fields, required by the control plane's
   request validation, not the machine.
4. **Certificate SANs must include the public IPs.** Azure public IPs
   are NAT; nothing puts them in the certs by default, and every
   non-insecure talosctl call fails TLS. `bootstrap.sh` passes
   `--additional-sans` with every public IP and REGENERATES configs when
   the control plane's current IP is missing — public IPs change every
   rebuild. (Phase 2's `--apiserver-cert-extra-sans`, Talos edition.)
5. **talosctl has a fixed ~10s dial deadline and no timeout flag.** On a
   client network path where the mTLS handshake takes just over 10s
   (anonymous TLS instant, raw TCP instant — path-specific), bootstrap
   fails forever with a misleading `dial tcp ... i/o timeout`. The gRPC
   trace shows the connection reaching READY exactly as the deadline
   cancels it. Escape hatch: run talosctl INSIDE the VNet — a one-shot
   ACI container in `snet-aci` (10.0.2.0/24, delegated to
   ContainerInstance, provisioned by the Pulumi program) against the
   control plane's PRIVATE IP. kubectl on :6443 is unaffected.
6. **`talos-check-ip` accumulates admin IPs** (comma list, one NSG rule
   per port per CIDR) instead of replacing — a replace-on-drift guard
   re-locked us out mid-bootstrap when the laptop's network flipped.
7. **Storage on an immutable FS**: local-path-provisioner's default
   `/opt` path is read-only on Talos. `patch-common.yaml` bind-mounts
   `/var/mnt/local-path` into the kubelet ahead of time.

## Diagnosis order when talosctl times out

The same symptom had three different causes on three consecutive runs.
Check in this order, cheapest first:

1. `make talos-check-ip` — is your CURRENT egress IP admitted?
2. `nc -z <node> 50000` — does raw TCP connect? If yes but talosctl
   fails, it is NOT the firewall.
3. `talosctl -n <ip> version --insecure` — "tls: certificate required"
   is GOOD news: the node is configured and serving; your certs or your
   path are the problem, not the node.
4. `GRPC_GO_LOG_SEVERITY_LEVEL=info GRPC_GO_LOG_VERBOSITY_LEVEL=2
   talosctl ...` — if the subchannel reaches READY right as the call
   dies, you have gotcha #5: use the in-VNet jump container.

## Version note

Talos pins its bundled Kubernetes: v1.13.9 ships v1.36.2 (the kubeadm
era ran v1.36.4 at the time). Upgrading k8s on Talos is
`talosctl upgrade-k8s`, a separate lab.
