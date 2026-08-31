# 2026-08-31 — Phase 8, Session B: the data outlived the operating system

One script (`cluster-talos/platform.sh`), one stall, one fix, and then the
sentence the whole phase was built to earn. The restored database's
verdict, verbatim:

    vms:      3        k8s-cp-1
    ips:      9        k8s-worker-1
    prefixes: 4        k8s-worker-2
    sites:    1
    ContinuousArchiving=True

The exact final state of the kubeadm era, served by a Postgres born on a
Talos node from `pg-gen4-20260827` — the archive the last Ubuntu cluster
wrote. This data has now survived: five pods, a node, a Valkey, a PITR
target, four full cluster destroys, a rolling app upgrade, an unpinned
secret rotation, **the operating system, and the bootstrap method**. And
the detail worth framing: the inventory on the Talos machines describes
the Ubuntu machines — NetBox's records of `k8s-cp-1` living on
`talos-cp-1`, a database remembering hardware that no longer exists.

## What went right, first try

- **Cilium via KubePrism.** On kubeadm, `k8sServiceHost` had to be
  injected per-provider from the inventory — the one provider-specific
  wart in the Cilium install. Talos ships KubePrism (localhost:7445, on
  by default), making it a constant. Nodes went Ready on the first
  attempt with the documented capability lists and cgroup pinning.
- **The kubelet extraMounts pre-empt worked**: `/var/mnt/local-path` was
  waiting for the provisioner, staged in `patch-common.yaml` before the
  first boot.
- **Azure IMDS from a Talos pod**: barman read the archive and writes the
  new generation over the same node-identity path as every era. No
  hop-limit drama, no Talos-specific surprises.
- **The plugin's interoperability, again**: an archive written by the
  plugin on Ubuntu, read by the plugin on Talos. Format is format.

## The one stall: Talos enforces Pod Security admission, kubeadm never did

`local-path`'s hostPath helper pod was refused outright:
`violates PodSecurity "baseline:latest": hostPath volumes`. On every
kubeadm cluster this project has run, PSS enforcement was simply absent,
so the difference was invisible for the project's entire life. Fix: label
the provisioner's namespace `pod-security.kubernetes.io/enforce=privileged`.

That makes THREE invisible-on-Ubuntu defaults Talos surfaced in one
session: the immutable `/opt` (pre-empted), the missing kube-proxy
bootstrap VIP (dissolved by KubePrism), and cluster-wide PSS (collided
with, fixed in one label). Secure-by-default is not a brochure word here;
it is admission-controller behavior.

## Scope honesty

This was the MINIMAL platform: no gateway, no cert-manager issuers, no
ArgoCD, no NetBox app serving traffic. Those re-prove Phases 5/6.5 rather
than testing Talos, and four days remain on the credits. The comparison
verdict is ADR 012; the era now ends with the teardown-to-zero.
