# 9.0 diff — the worksheet against the answer key

`phase9/9.0/commands.md` (what was done by hand, Azure 09-01→03 and
Hetzner 09-04→09) compared with `cluster/prep-node.sh`,
`cluster/bootstrap.sh`, `cluster/platform.sh` and
`cluster/addons/cilium/values.yaml`. Written 2026-09-09 by Claude at the
user's request; the items marked **open the script** are the ones worth
reading in the source rather than taking from here — each is a decision
the scripts made that the hand build didn't have to.

Three questions, in order.

---

## 1. What the scripts do that the hand build didn't

### prep-node.sh (runs ON a node)

| the script | the worksheet | why it's there |
|---|---|---|
| `set -euo pipefail` at the top | pasted commands, kept going after failures | one failed `apt` line on 09-01 left a half-written `kubernetes.list` that broke every later `apt` call. `-e` stops at the first error so the damage never compounds |
| `hostnamectl set-hostname "$NODE_NAME"` | not done — nodes registered under whatever the cloud named them | node names come from the inventory contract, not the image. On Hetzner the cloud name matched by luck (`k8s-cp-1`) |
| **swap: checks and REFUSES** (`exit 1` if `swapon --show` is non-empty) | `swapoff -a` + `sed` on fstab | **open the script.** The script deliberately does not fix swap — it treats swap-on as "this is not a node image I recognise." Both are defensible; the worksheet's version is friendlier, the script's is stricter |
| **A3.5 apt mirror normalization** — rewrites `<region>.ec2.archive.ubuntu.com` / `azure.archive.ubuntu.com` to `archive.ubuntu.com` | nothing | **open the script** — the comment is a whole lesson: cloud-local mirror hostnames are DNS pools that can contain dead members; you can't probe your way out of a lottery, so don't play. Hetzner images point at Hetzner's mirror; not hit yet |
| `DEBIAN_FRONTEND=noninteractive`, `-yq` | `-y` | no prompt can ever block an unattended run |
| **`sandbox_image = "registry.k8s.io/pause:3.10"`** in containerd's config | nothing | kubeadm warns when containerd's pause image differs from the one kubeadm expects; the script aligns them so the warning (and a second pause image on every node) never appears |
| `systemctl enable containerd` | only `restart` | survives a reboot. The worksheet's runtime would come back (the package enables it), so this is belt-and-braces |
| `gpg --dearmor --yes` | `gpg --dearmor` | idempotency: re-running prep on a prepped node must not stop at "file exists" |
| `K8S_MINOR="v1.36"` as a variable with a comment about the upgrade lab | `v1.36` typed inline twice | one place to bump; the comment records *why* it's pinned where it is |
| installs `cri-tools` and writes `/etc/crictl.yaml` | not installed — which is why `crictl ps` printed nothing during the 09-04 debugging | `crictl` is how you look at containers on a node without kubectl. Cheap, and the first tool you want when kubelet is unhappy |

Not in the script, present in the worksheet: nothing for one-door
providers. The **Hetzner column** (`--node-ip`) is section 2.

### bootstrap.sh (runs on the LAPTOP)

| the script | the worksheet | why it's there |
|---|---|---|
| reads **everything** from the inventory JSON — IPs, `sshUser`, roles | IPs typed by hand from `make nodes`, and once from the *previous build's* commands (the stale `49.12.65.53` kubeconfig on 09-08) | the contract exists so no IP is ever typed. The stale-IP mistake is exactly the failure it prevents |
| Step 0: **waits for SSH** on all nodes, 30 tries × 5s, in parallel | ssh'd when the console said running | fresh instances accept SSH 30–60s after "running"; the script learned this as drill 1's race (2026-07-15) |
| Step 1: `scp` prep-node.sh to each node and runs it **in parallel**, logs to `/tmp/prep-<node>.log` | the same block pasted three times, serially, with paste-truncation errors | the loop over the inventory *is* the worksheet's "same block ×3" — recognised on 09-01, now seen |
| Step 2: **`--skip-phases=addon/kube-proxy`** on `kubeadm init` | not skipped — kube-proxy is running on this cluster | **open the script + values.yaml.** Cilium replaces kube-proxy (`kubeProxyReplacement: true`) and its Gateway API *requires* that. This cluster did not skip it, so **9.2's Gateway will need kube-proxy removed and Cilium upgraded with `kubeProxyReplacement=true` + `k8sServiceHost`** — doable live, no rebuild |
| Step 3: **`kubeadm token create --print-join-command`** on cp-1, captured into a variable, run on workers | the join line copied from init output — with the live token, which then got **committed to git twice** | tokens are generated on demand and never pass through a human. This is the fix for the token-in-git problem, not "remember to scrub" |
| idempotency guards: skips init if `admin.conf` exists, skips join if `kubelet.conf` exists | `kubeadm reset -f` by hand after the failed init | re-running the script on a half-built cluster is safe; the hand build needed a manual reset |
| Step 4: kubeconfig via `sudo cat /etc/kubernetes/admin.conf`, then `sed` private→public **from variables**, with a macOS/Linux `sed -i` fallback | `scp` of `.kube/config` and a `sed` with typed IPs | same idea, no typing. The `2>/dev/null \|\| sed -i` dance is the BSD-vs-GNU sed difference you hit with `sed -i ''` |
| **Step 4.5: apiserver STABILITY gate** — 5 consecutive `/readyz` OKs, 5s apart | went straight to Helm; **the first Cilium install failed and left a `failed` release** on 09-08 | **open the script.** "kubeadm init returning ≠ apiserver settled" — on small nodes etcd stalls for the first minutes and the next big write (Cilium's ~1MB release secret) gets dropped. The worksheet hit exactly this. The script demands N consecutive healthy answers, not one |
| Step 5: **Gateway API CRDs** applied *before* Cilium, with 3 retries | not applied | Cilium only registers its Gateway controller if the CRDs exist at start. 9.2 needs these too |
| Cilium from **`values.yaml`** + `--set k8sServiceHost=<cp private>` | `--set ipam.mode=kubernetes --set MTU=1400` inline | see values.yaml below. `k8sServiceHost` is provider-specific (an IP) so it comes from the inventory, not the file — the same "what belongs where" rule as the whole seam |
| Cilium install **retried 3×, uninstalling between attempts** | one attempt, manual `helm uninstall`, second attempt | the script's retry loop is the worksheet's 09-08 experience, automated. "Seen twice now, once per cloud" — now three times, two clouds |
| Step 6: `kubectl wait --for=condition=Ready node --all` | `kubectl get nodes` by eye | the script blocks until true; a human polls |

### cilium/values.yaml

| the file | the worksheet | why |
|---|---|---|
| `ipam.mode: cluster-pool` with `clusterPoolIPv4PodCIDRList: [10.244.0.0/16]` | `ipam.mode=kubernetes` | **two valid answers to the same problem** (Cilium's default pool `10.0.0.0/8` overlaps the node network on every provider used). The file pins Cilium's own pool to the kubeadm CIDR; the worksheet tells Cilium to use the per-node CIDRs kubeadm already allocated. `kubernetes` mode is simpler and needs no CIDR repeated; `cluster-pool` is Cilium's default and what the runbooks describe. Either way the value came from `--pod-network-cidr` |
| `kubeProxyReplacement: true` | absent (kube-proxy present) | see Step 2 above — the 9.2 dependency |
| `gatewayAPI.enabled: true`, `hostNetwork.enabled: true` | absent | the edge, on fixed ports 30080/30443, no cloud LB — the portable successor to NodePorts. 9.2 |
| `hubble.relay/ui enabled` | absent | observability. Not needed for 9.0; wanted for 9.3's failover drill |
| `operator.replicas: 1` | default (2) | two operators on a 3-node lab is a wasted pod |
| routing mode deliberately unset (vxlan) | same | portable |
| **no MTU** | `MTU=1400` | the file has no Hetzner knowledge. Section 2 |

### platform.sh

| the script | the worksheet | why |
|---|---|---|
| **local-path-provisioner as the DEFAULT StorageClass**, cloud CSI as an *opt-in* named class | the CSI class **is** the default; no local-path | **a genuine design difference, open the script.** Phase 4 chose portable-by-default (local-path works on-prem) and cloud disks as a named upgrade. The worksheet chose cloud disks by default. For a lab that always runs on a cloud, the worksheet's choice is simpler and CNPG gets real disks without naming a class; the script's choice keeps `none` (on-prem) working unchanged. Worth deciding on purpose for the Hetzner branch |
| `--provider=aws\|azure\|none` case for the CSI addon | hand-installed hcloud-csi | **no `hetzner` case exists** — section 2 |
| `helm_i` wrapper: skip-if-installed + **retry loop for small nodes** | plain `helm install` | idempotency + the same etcd-stall tolerance as bootstrap's Step 4.5 |
| metrics-server | not installed | `kubectl top`; needed for anything HPA-shaped later |
| cert-manager **with values + Let's Encrypt/Cloudflare issuers + the token secret from a local file** | cert-manager bare (`crds.enabled=true`) | the worksheet installed it only as the barman plugin's mTLS dependency; the script installs it as the public-TLS system for the Gateway. 9.2 needs the issuers |
| barman plugin v0.14.0 with a create-namespace guard and rollout wait | same manifest, by hand | identical in substance — the worksheet got this one right |
| Gateway `main` from `addons/gateway/gateway.yaml` | not installed | 9.2 |
| Postgres / NetBox credentials from `~/.config/trk-k8s/*` files into Secrets | `make pg-backup-secret` (new, Pulumi-sourced) | same principle — secrets from local state, never git — different source. The new target is the better pattern for cloud credentials; files remain right for app passwords |
| **ArgoCD + root app** — the CNPG *operator* is installed by ArgoCD (`cluster/gitops/apps/cnpg-operator.yaml`), not by platform.sh | CNPG operator by `helm install` | the answer key's cluster is GitOps-managed above the platform layer. This cluster is not (yet). 9.1/9.2 should decide whether Hasura and the finance DB land via ArgoCD or by hand |

---

## 2. What the hand build did that the scripts don't — the Hetzner column

Every item here is a line in a future `--provider=hetzner` branch.

| item | where it was done by hand | where it belongs |
|---|---|---|
| ssh as **`root`** | typed | already in the contract (`sshUser`); bootstrap.sh reads it; the Makefile was fixed 09-03. **Done** |
| private NIC netplan patch | on each node, 09-04 and worker-1 on 09-08 | `infra/hetzner/main.go` cloud-init `user_data` — **committed `ec79742`, pending a chosen rebuild** |
| **`--node-ip=10.0.1.x`** in `/etc/default/kubelet` | end of prep, each node | `prep-node.sh`: a provider hook that writes `KUBELET_EXTRA_ARGS` from the inventory's `privateIp` — or better, bootstrap.sh passing a kubeadm config with `nodeRegistration.kubeletExtraArgs.node-ip`. Harmless on one-door providers (it'd set the address kubelet already picks), so it could simply be **unconditional** |
| **Cilium `MTU=1400`** | `--set` at install | a Hetzner values overlay (`addons/cilium/values-hetzner.yaml`) merged after `values.yaml`; bootstrap.sh picks it by provider. Or derive: `1450 − 50` from `/sys/class/net/enp7s0/mtu` — clever, but a literal with a comment is clearer |
| **hcloud API token → Secret `kube-system/hcloud`** | `kubectl create secret … --from-file` | `platform.sh` hetzner case, from `~/.config/trk-k8s/hcloud-token` — same pattern as the Cloudflare token |
| **hcloud-csi** with `storageClasses=[]` | `helm install` by hand | `platform.sh` hetzner case via `helm_i` |
| **StorageClass `hcloud-csi`** (`csi.hetzner.cloud`, default, WFFC, expandable) | `phase9/9.0/storageclass.yaml` | `cluster/addons/hcloud-csi/storageclass.yaml`, applied by the hetzner case — and the *default-class decision* from section 1 made explicitly |
| **static IAM key for barman** (off-AWS clusters) | `make persist-up` + `make pg-backup-secret` | done as Makefile targets — arguably right where they are, since it's cross-provider plumbing. platform.sh's hetzner case could call `pg-backup-secret` |
| ObjectStore in **S3-credentials form** | `phase9/9.0/objectstore.yaml` | `apps/postgres-cnpg/base/objectstore.yaml` is Azure-form (`inheritFromAzureAD`) — needs a Hetzner/S3 overlay, or the base rewritten to S3 (which is where the archive lives now regardless of provider) |
| `make capacity` / `guard` / `admit` / stock rule | Makefile | done |

---

## 3. Where the answer key was wrong, or silent

| finding | status |
|---|---|
| **azuredisk-csi-driver chart ≥1.34 breaks `platform.sh`'s azure case** — controller demands a cloud config (`allowEmptyCloudConfig` default flipped; IMDS discovery removed). The comment "needs no cloud-config plumbing" is no longer true | not fixed — Azure is closed. Record: the fix is a `kube-system/azure-cloud-provider` Secret built from Pulumi outputs. Left as a note in case Azure returns |
| **Makefile hardcoded `ubuntu@`** despite `sshUser` in the contract | fixed 09-03 |
| `platform.sh` has **no `hetzner` provider** | section 2 is the spec |
| `bootstrap.sh` Step 0's lockout hint says "AWS: make check-ip && make up" | now `make admit`, any provider. Trivial, should be updated |
| `values.yaml`'s comment: "10.0.0.0/16 on AWS and Hetzner alike" | still true — and the reason both `cluster-pool` and `kubernetes` IPAM modes had to avoid it |
| **no knowledge anywhere of two-door providers** — no `node-ip`, no MTU, no NIC readiness check | runbook 09 + the network-models note are the knowledge; the branch in section 2 is the code |
| `platform.sh` installs **local-path as default**, so on a fresh Hetzner run CNPG would land on node-local disks unless a class is named | decide: keep (portable) or make the cloud CSI default when a provider is set |

---

## What to do with this

The section-2 table is a work order. Suggested shape, smallest first:

1. `prep-node.sh`: write `--node-ip` from the inventory unconditionally
   (one-door providers are unaffected). bootstrap.sh already knows each
   node's `privateIp`; pass it as the second argument.
2. `addons/cilium/values-hetzner.yaml` with `MTU: 1400`; bootstrap.sh
   takes `--provider` and adds `-f` for it.
3. `platform.sh` hetzner case: token Secret, `helm_i hcloud-csi` with
   `storageClasses=[]`, apply `addons/hcloud-csi/storageclass.yaml`.
   Decide the default-class question while writing it.
4. `apps/postgres-cnpg/base/objectstore.yaml` → S3 form; the Azure form
   goes to git history with the era.
5. Fix the Step 0 hint. Update `platform.sh`'s azure comment with the
   chart-break note.

Then a rebuild on a day `make capacity` says yes — `make up FORCE=1`
(the cloud-init fix lands), `make bootstrap`, `make platform
--provider=hetzner` — is the test of all of it, and it should end with
`ContinuousArchiving=True` and no hand-typed command.
