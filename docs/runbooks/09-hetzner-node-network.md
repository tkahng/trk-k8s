# Runbook 09 — Hetzner node network: the two doors

Written 2026-09-08, after the procedure had been done by hand twice
(Sept 4 and Sept 8) — this project's bar. Covers what a fresh Hetzner
node needs *before* `kubeadm init`/`join` that an AWS or Azure node does
not. Background and the reasoning: `docs/notes/provider-network-models.md`.
If you are on AWS, none of this applies — skip to runbook 02.

## The five-year-old version

Every Hetzner server is a house with **two doors**.

- The **front door** faces the public street: `eth0`, the public IP.
  Anyone on the internet can walk up to it, so there is a bouncer (the
  Hetzner firewall) who only lets *you* in.
- The **back door** opens onto a private courtyard shared only by your
  three houses: `enp7s0`, the `10.0.1.x` address. No bouncer — only your
  houses can reach the courtyard.

Three things go wrong, and each has a one-line fix:

1. **The back door has no handle.** Hetzner bolts the back door onto the
   house *while it's being built*, but sometimes finishes after Ubuntu
   has already decided which doors it has. The door exists (`enp7s0`)
   but nobody can use it (DOWN, no IP). **Fix: tell Ubuntu "any back
   door you find, use it" — a netplan rule.**
2. **Each house introduces itself by its front-door address.** When
   kubelet registers, it says "reach me at…" and picks the door that
   leads to the street. Then cp-1 tries to hand worker-1 a package by
   walking around the block to the *front* door, and the bouncer turns
   it away. **Fix: tell kubelet "introduce yourself by the back door" —
   `--node-ip`.**
3. **The back door is narrower.** The courtyard path carries 1450-byte
   packets, the street carries 1500. Cilium measures the street and
   sends 1450-byte packages down the 1450 path — plus its own 50-byte
   wrapping — and they don't fit. Small things (pings, DNS) pass; big
   things (image pulls, backups) silently jam. **Fix: tell Cilium the
   real width — `MTU=1400`.**

AWS and Azure houses have **one door**: the private address on the only
NIC, with the cloud translating the public address at the street. Every
"pick the door" decision has one answer there, so none of this comes up.

## Step by step (per node, before kubeadm)

Reproduce from memory by remembering the order **look → handle → name →
width**.

### 1. Look — how many doors, which are open

```
ip -4 -brief addr            # want: eth0 <public>  AND  enp7s0 10.0.1.x
ip route | grep ^10          # want: 10.0.0.0/16 via 10.0.0.1 dev enp7s0
```

If `enp7s0` shows `10.0.1.x`: skip step 2. If it is missing from `ip -4`
(it only lists interfaces that HAVE an IPv4), confirm the door exists:

```
ip -brief link               # enp7s0 present but DOWN = step 2
```

Sanity check on what Hetzner *thinks* it attached:

```
curl -s http://169.254.169.254/hetzner/v1/metadata/private-networks
```

### 2. Handle — configure the private NIC (only if step 1 failed)

```
printf 'network:\n  version: 2\n  ethernets:\n    enp7s0:\n      dhcp4: true\n' > /etc/netplan/60-private-net.yaml
chmod 600 /etc/netplan/60-private-net.yaml
netplan apply
ip -4 -brief addr show enp7s0        # want: UP 10.0.1.x
ping -c1 10.0.1.10                   # from a worker: cp-1 answers
```

Why DHCP and not a static address: Hetzner's DHCP on the private network
hands out exactly the fixed IP you assigned in Pulumi, plus the route to
`10.0.0.0/16`. Static config would duplicate what the cloud already knows.

### 3. Name — make kubelet register the private address

At the end of node prep, after the kubelet package is installed, before
`kubeadm init` or `join`. Each node uses ITS OWN private IP (`.10` cp-1,
`.11` worker-1, `.12` worker-2 — `make nodes`):

```
echo 'KUBELET_EXTRA_ARGS=--node-ip=10.0.1.10' > /etc/default/kubelet
systemctl restart kubelet
```

Verify after the node joins, from wherever kubectl works:

```
kubectl get nodes -o wide            # INTERNAL-IP column: 10.0.1.x, never public
```

Do this BEFORE installing Cilium. Cilium reads node addresses when its
agents start; fixing InternalIP afterwards means restarting every agent.

### 4. Width — Cilium's MTU

Once, at install, from the laptop:

```
helm install cilium cilium/cilium --version 1.19.4 --namespace kube-system \
  --set ipam.mode=kubernetes --set MTU=1400
```

Where 1400 comes from: `cat /sys/class/net/enp7s0/mtu` → 1450, minus 50
bytes of VXLAN. Verify after the agents are Running:

```
kubectl -n kube-system exec ds/cilium -- ip link show cilium_host | grep -o 'mtu [0-9]*'   # mtu 1400
```

## Where each fix lives permanently

| step | permanent home | status |
|---|---|---|
| 2 handle | `infra/hetzner/main.go` — cloud-init `user_data` writes the netplan rule for any `enp*` NIC at first boot, so step 2 is never needed by hand | committed `ec79742`; applies on the next rebuild (`user_data` replaces servers); **unverified until then** |
| 3 name | `cluster/prep-node.sh` — `nodeRegistration.kubeletExtraArgs.node-ip` in the kubeadm config, from the inventory's `privateIp` | TODO after the 9.0 diff |
| 4 width | `cluster/addons/cilium/values.yaml` — `MTU: 1400` under a Hetzner overlay, or `platform.sh --provider=hetzner` | TODO after the 9.0 diff |

Until those land, this runbook IS the procedure. When they land, step 1
becomes the only manual step — a check, not a fix.

## What it looked like when it was wrong

- `kubeadm init`: `error execution phase wait-control-plane … Post
  "https://10.0.1.10:6443/…": context deadline exceeded` — the address
  wasn't on the box (step 2).
- `kubeadm join` on a worker: `couldn't validate the identity of the API
  Server … Get "https://10.0.1.10:6443/…": context deadline exceeded` —
  same thing, from the other side (step 2 on the worker).
- `kubectl get nodes -o wide` showing public addresses under INTERNAL-IP
  (step 3). Later symptom if missed: `kubectl logs`/`exec` time out.
- Everything works except large transfers hang (step 4 missed).
