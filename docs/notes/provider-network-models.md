# Provider network models: one door vs two doors

Written 2026-09-04, the night the fourth provider swap (Azure → Hetzner)
broke `kubeadm init` at `wait-control-plane` and then registered every
node under its public IP. Neither happened on AWS or Azure. The difference
is not a bug in any of the three; it's two different models of what "a
server with a public IP" means, and the `cluster/` layer had silently
assumed one of them.

## The two models

**AWS and Azure: one door.** A VM has a single NIC carrying its *private*
address (10.0.1.10). The public address is not on the machine at all — the
cloud NATs it at the edge (Elastic IP / Azure Public IP resource) onto that
private NIC. From inside the OS, `ip addr` shows only 10.0.1.10. Every
component that "picks the interface with the default route" — kubelet's
node IP, kubeadm's default advertise address, Cilium's device selection —
picks the private address, because it is the only address.

**Hetzner: two doors.** A server has a real public NIC (`eth0`, e.g.
49.12.65.53, the default route) AND a real private NIC (`enp7s0`,
10.0.1.10) attached to a Hetzner Network. Both addresses are on the
machine. Anything that "picks the default-route interface" picks the
**public** one — which is exactly wrong for cluster-internal traffic.

The firewall model follows from this: Hetzner firewalls filter only the
public interface (ADR 002 noted this); AWS security groups and Azure NSGs
filter the single NIC and therefore everything. So on Hetzner,
cluster-internal traffic that accidentally uses public addresses is
**blocked by the admin-only firewall** — the firewall doing its job
becomes the failure mode.

## What broke, and the fix for each

| symptom | cause | live fix | durable fix |
|---|---|---|---|
| `kubeadm init` times out at `wait-control-plane`; API server can't bind `10.0.1.10` | `enp7s0` present but DOWN, no IP: Pulumi creates the server, then attaches the network as a separate `ServerNetwork` resource, so cloud-init had already written netplan for `eth0` only; the private NIC was hot-plugged unconfigured | `/etc/netplan/60-private-net.yaml` with `enp7s0: dhcp4: true`, `netplan apply` (Hetzner's DHCP hands out the fixed IP + route to 10.0.0.0/16) | attaching at creation (`ServerArgs.Networks`, `c0589a0`) turned out to be a **race**: on 2026-09-08 cp-1 and worker-2 booted with the NIC configured, worker-1 didn't — Hetzner attaches asynchronously either way. Actual durable fix: cloud-init `user_data` writing a netplan rule that DHCPs any `enp*` NIC (networkd applies match rules to hot-plugged interfaces). Committed; applies on the next rebuild because `user_data` forces server replacement — unverified until then |
| nodes register `InternalIP` = public address; pod tunnel traffic and apiserver→kubelet (`logs`/`exec`) go over public IPs and hit the firewall | kubelet picks the default-route interface | `/etc/default/kubelet`: `KUBELET_EXTRA_ARGS=--node-ip=10.0.1.x`, `systemctl restart kubelet` | `nodeRegistration.kubeletExtraArgs.node-ip` in the kubeadm init/join config, i.e. set before the node registers — `prep-node.sh`'s job on Hetzner |
| `ssh ubuntu@` fails | Hetzner images log in as `root` | — | already in the contract (`sshUser`); the Makefile had hardcoded `ubuntu` and was fixed 2026-09-03 |
| small traffic fine, large transfers hang (image pulls, big `logs`, base backups) | **MTU.** `eth0` is 1500 but `enp7s0` is **1450** (Hetzner's own encapsulation). Cilium autodetects from the default-route device (eth0 → 1500), gives pods 1450; pod traffic then rides `enp7s0` where 1450 + 50 VXLAN > 1450 — silently dropped | — (prevented at install) | `--set MTU=1400` on the Cilium install (1450 − 50). The back door is not just the private one; it's *narrower* |

Cilium's `ipam.mode=kubernetes` and the `--pod-network-cidr` story are
unchanged across all three providers; those live above this layer.

## What this says about the seam

The inventory contract (`cluster/README.md`) carries `privateIp` and
promises the cluster layer can use it. On AWS/Azure that promise is
free. On Hetzner the contract is *true* (the address is allocated and
routable) but the OS needs two nudges before it's *usable* — configure
the NIC, and tell kubelet to prefer it. Both nudges are provider-specific
and belong in layer 1 or in `prep-node.sh`'s provider hook, not in the
provider-agnostic scripts. Revised claim, consistent with the Talos
finding (Phase 8): the seam absorbs a cloud swap completely **as long as
the cloud presents one door**; a two-door provider needs the OS told
which door is for family.

## Quick diagnostic, any provider

```
ip -4 -brief addr                      # how many doors, which has 10.0.1.x
ip route | head -3                     # which door has the default route
kubectl get nodes -o wide              # INTERNAL-IP must be 10.0.1.x
```

If INTERNAL-IP is public on a two-door provider, fix it before installing
the CNI; Cilium caches node addresses and a later change means restarting
agents.
