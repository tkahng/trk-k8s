# cluster/ — the provider-agnostic layer

Everything in this directory treats machines as interchangeable. It must work
identically whether the nodes came from `infra/aws`, `infra/hetzner`, or a rack
in a closet — that's the portability guarantee of this project.

## The node inventory contract

Every infra stack (and any hand-written inventory for on-prem machines) provides
a `nodes` output with exactly this shape:

```json
[
  {
    "name": "k8s-cp-1",
    "role": "control-plane",
    "publicIp": "203.0.113.10",
    "privateIp": "10.0.1.10",
    "sshUser": "ubuntu"
  },
  { "name": "k8s-worker-1", "role": "worker", "publicIp": "...", "privateIp": "10.0.1.11", "sshUser": "ubuntu" }
]
```

Get it from a Pulumi stack with:

```sh
pulumi stack output nodes
```

For on-prem, write the same JSON by hand into a file. Nothing downstream knows
the difference.

Rules that keep this layer portable:

- Only Ubuntu 24.04 is assumed (same image everywhere), reachable over SSH at
  `publicIp` as `sshUser`.
- Cluster-internal traffic always uses `privateIp` — kubeadm advertises it,
  etcd binds it, kubelets register it.
- No cloud APIs are called from this layer. Cloud-specific conveniences
  (cloud-controller-managers, CSI drivers, cloud load balancers) are optional
  per-environment addons, documented separately, and the cluster must remain
  functional without them.

## Contents (grows as we go)

- Phase 2 runbook: bootstrap kubeadm manually — see `docs/runbooks/`
- Later (Phase 6): scripts that automate the runbook against any inventory
