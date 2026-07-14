# 2026-07-14 — Phase 2: the cluster exists

Bootstrapped Kubernetes v1.35.6 by hand following runbook 02: 1 control plane
+ 2 workers, all registered, all NotReady (correct — no CNI until Phase 3).
Verified from the laptop over the public IP, proving the
`--apiserver-cert-extra-sans` flag worked.

## Decisions along the way

- Considered switching to **Talos** to eliminate the manual SSH work (ADR
  004): deferred — Phase 2's entire point is seeing the machinery Talos
  hides. Automation stays the Phase 6 answer; Talos is a comparison lab.
- Postgres-in-k8s added as **Phase 7** end-goal (PgBouncer → Patroni →
  operators → Saleor/Supabase capstone).

## Gotchas actually hit (the real learning)

1. **`crictl` missing** — Ubuntu's containerd package doesn't ship it and
   kubeadm didn't pull it in; it's the `cri-tools` package in the pkgs.k8s.io
   repo, plus `/etc/crictl.yaml` pointing at containerd's socket. Runbook
   amended.
2. **`kubeadm join` failed: "user is not running as root"** — forgot `sudo`.
   Preflight checks fail fast and clearly; first error in the list is the one
   that matters.
3. **Multi-line paste mangled the join command** — the CA hash wrapped across
   lines; the shell ran the tail of the hash as its own command
   (`226a51...: command not found`) and the join used a truncated hash.
   Lesson: join commands as one line, always.
4. **Hostname must be set BEFORE join** — worker prompt still said
   `ip-10-0-1-11`; node name is captured at registration and is immutable
   after. Caught it just in time. (Also: don't paste live join tokens into
   git-tracked docs — scratch file instead.)

## Observed and understood

- Control plane runs as **static pods** from `/etc/kubernetes/manifests/` —
  the kubelet runs them straight from disk; no scheduler involved. That's how
  the control plane hosts itself.
- Control-plane pods are Running with no CNI because they're on **host
  network**; CoreDNS is Pending because it needs a pod network — the visible
  difference between the two.
- `kube-proxy` runs per node as a DaemonSet even before CNI.
- Cluster state: `kubectl get nodes` NotReady × 3 = Phase 2 success.

## Phase 3, same day: Cilium

Installed Cilium 1.19.4 via Helm entirely from the laptop — zero SSH. The
CNI is just workloads on the cluster; first real taste of "the cluster is
the API".

- The one critical value: `clusterPoolIPv4PodCIDRList: [10.244.0.0/16]`.
  Cilium's default pool (10.0.0.0/8) contains the VPC — pods would have
  collided with machines. Matched kubeadm's `--pod-network-cidr` instead.
- Watched the causal chain live: helm install → cilium agents Running →
  nodes flip NotReady→Ready → CoreDNS finally schedules and gets a
  10.244.x.x pod IP (it waited 24 minutes for a network to exist).
- `cilium connectivity test`: **79/80 tests, 692 actions** — the one
  "failure" was the log-hygiene meta-check flagging two `context canceled`
  errors in the hubble-ui backend from a disconnected browser session.
  Every actual traffic path (cross-node, services, DNS, L7, policy
  allow/deny) passed. On 2-vCPU nodes the suite takes ~15 min.
- Lesson (mine): don't pipe long-running commands through `tail` — the
  output stays invisible until exit. Stream to a log file instead.

Cluster is now fully functional. Kept kube-proxy (replacement is a later
lab); vxlan tunnel routing (portable default).
