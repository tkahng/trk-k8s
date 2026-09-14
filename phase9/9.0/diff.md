# 9.0 diff — the worksheet against the answer key

`phase9/9.0/commands.md` (done by hand: Azure 09-01→03, Hetzner
09-04→09) compared with `cluster/prep-node.sh`, `cluster/bootstrap.sh`,
`cluster/platform.sh` and `cluster/addons/cilium/values.yaml`. Written
2026-09-09 at the user's request. Items marked [OPEN THE SCRIPT] are
worth reading in the source — each is a decision the scripts made that
the hand build never had to.

Format per item:  what the script does  /  what the worksheet did
                  -> why it's there


================================================================
1. WHAT THE SCRIPTS DO THAT THE HAND BUILD DIDN'T
================================================================

--- prep-node.sh (runs ON a node) ------------------------------

* set -euo pipefail  /  pasted commands that kept going after errors
  -> one failed apt line on 09-01 left a half-written
     kubernetes.list that broke every later apt call. -e stops at
     the first error so damage never compounds.

* hostnamectl set-hostname "$NODE_NAME"  /  not done
  -> node names come from the inventory contract, not the cloud
     image. On Hetzner they matched by luck.

* swap: CHECKS and REFUSES (exit 1 if swapon shows anything)
  /  swapoff -a + sed on fstab
  -> [OPEN THE SCRIPT] the script deliberately does not fix swap:
     swap-on means "not a node image I recognise". The worksheet's
     version is friendlier, the script's is stricter. Both defensible.

* A3.5 apt mirror normalization: rewrites the cloud-local mirror
  (<region>.ec2.archive..., azure.archive...) to archive.ubuntu.com
  /  nothing
  -> [OPEN THE SCRIPT] the comment is a whole lesson: cloud mirror
     hostnames are DNS pools that can contain dead members; you
     cannot probe your way out of a lottery, so don't play. Hetzner
     images point at Hetzner's mirror — not hit yet.

* DEBIAN_FRONTEND=noninteractive, apt -yq  /  apt -y
  -> nothing can ever prompt and block an unattended run.

* sandbox_image = "registry.k8s.io/pause:3.10" in containerd config
  /  nothing
  -> kubeadm warns when containerd's pause image differs from the
     one it expects; aligning them removes the warning and a second
     pause image on every node.

* systemctl enable containerd  /  only restart
  -> survives reboot. (The package enables it anyway; belt and braces.)

* gpg --dearmor --yes  /  gpg --dearmor
  -> idempotency: re-running prep must not stop at "file exists".

* K8S_MINOR="v1.36" as one variable with a comment  /  typed twice
  -> one place to bump; the comment records WHY it's pinned there.

* installs cri-tools and writes /etc/crictl.yaml  /  not installed
  -> crictl is how you look at containers on a node without kubectl.
     It's why `crictl ps` printed nothing during the 09-04 debugging.

--- bootstrap.sh (runs on the LAPTOP) --------------------------

* reads EVERYTHING from the inventory JSON: IPs, sshUser, roles
  /  IPs typed from `make nodes` — and once from the PREVIOUS
     build's commands (the stale 49.12.65.53 kubeconfig, 09-08)
  -> the contract exists so no IP is ever typed. The stale-IP
     mistake is exactly the failure it prevents.

* Step 0: waits for SSH on all nodes, 30 tries x 5s, in parallel
  /  ssh'd as soon as the console said "running"
  -> fresh instances accept SSH 30-60s after "running". Drill 1's
     race, 2026-07-15.

* Step 1: scp prep-node.sh to each node, run in PARALLEL, log to
  /tmp/prep-<node>.log  /  same block pasted 3x, serially, with
  paste-truncation errors
  -> the loop over the inventory IS the worksheet's "same block x3",
     recognised on 09-01.

* Step 2: --skip-phases=addon/kube-proxy on kubeadm init
  /  not skipped — kube-proxy is running on THIS cluster
  -> [OPEN THE SCRIPT + values.yaml] Cilium replaces kube-proxy
     (kubeProxyReplacement: true) and its Gateway API REQUIRES that.
     CONSEQUENCE FOR 9.2: this cluster needs kube-proxy removed and
     Cilium upgraded with kubeProxyReplacement=true + k8sServiceHost
     before Hasura gets an HTTPRoute. Doable live, no rebuild.

* Step 3: `kubeadm token create --print-join-command` on cp-1,
  captured into a variable, run on the workers
  /  join line copied from init output — with the live token, which
     then got COMMITTED TO GIT twice
  -> tokens are generated on demand and never pass through a human.
     This is the fix for token-in-git, not "remember to scrub".

* idempotency guards: skip init if admin.conf exists, skip join if
  kubelet.conf exists  /  `kubeadm reset -f` by hand after the
  failed init
  -> re-running on a half-built cluster is safe.

* Step 4: kubeconfig via `sudo cat /etc/kubernetes/admin.conf`, sed
  private->public FROM VARIABLES, with a macOS/Linux sed fallback
  /  scp of .kube/config + sed with typed IPs
  -> same idea, no typing. The `sed -i '' ... || sed -i` dance is
     the BSD-vs-GNU sed difference behind your `sed -i ''`.

* Step 4.5: apiserver STABILITY gate — 5 consecutive /readyz OKs,
  5s apart  /  went straight to helm; the first Cilium install
  FAILED and left a `failed` release (09-08)
  -> [OPEN THE SCRIPT] "kubeadm init returning != apiserver
     settled". On small nodes etcd stalls in the first minutes and
     the next big write (Cilium's ~1MB release secret) is dropped.
     The worksheet hit exactly this. Demand N consecutive healthy
     answers, not one lucky one.

* Step 5: Gateway API CRDs applied BEFORE Cilium, 3 retries
  /  not applied
  -> Cilium only registers its Gateway controller if the CRDs exist
     when it starts. 9.2 needs these.

* Cilium from values.yaml + --set k8sServiceHost=<cp private IP>
  /  --set ipam.mode=kubernetes --set MTU=1400 inline
  -> see values.yaml below. k8sServiceHost is an IP, therefore
     provider-specific, therefore from the inventory not the file —
     the same "what belongs where" rule as the whole seam.

* Cilium install retried 3x, `helm uninstall` between attempts
  /  one attempt, manual uninstall, second attempt
  -> the script's retry loop is the worksheet's 09-08 experience,
     automated. "Seen twice, once per cloud" — now three times.

* Step 6: kubectl wait --for=condition=Ready node --all
  /  kubectl get nodes, by eye
  -> the script blocks until true; a human polls.

--- cilium/values.yaml -----------------------------------------

* ipam.mode: cluster-pool + clusterPoolIPv4PodCIDRList [10.244.0.0/16]
  /  ipam.mode=kubernetes
  -> TWO VALID ANSWERS to one problem: Cilium's default pool
     10.0.0.0/8 overlaps the node network on every provider used.
     The file pins Cilium's own pool to the kubeadm CIDR; the
     worksheet tells Cilium to use the per-node CIDRs kubeadm already
     allocated. `kubernetes` is simpler (no CIDR repeated);
     `cluster-pool` is Cilium's default and what the runbooks
     describe. Either way the value came from --pod-network-cidr.

* kubeProxyReplacement: true  /  absent (kube-proxy present)
  -> the 9.2 dependency, see Step 2.

* gatewayAPI.enabled + hostNetwork.enabled  /  absent
  -> the edge on fixed ports 30080/30443, no cloud LB. 9.2.

* hubble relay + ui  /  absent
  -> observability; wanted for 9.3's failover drill.

* operator.replicas: 1  /  default 2
  -> two operators on a 3-node lab is a wasted pod.

* routing mode deliberately unset (vxlan)  /  same
  -> portable.

* NO MTU  /  MTU=1400
  -> the file has no Hetzner knowledge. See section 2.

--- platform.sh --------------------------------------------------

* local-path-provisioner as the DEFAULT StorageClass; cloud CSI as
  an opt-in NAMED class  /  the CSI class IS the default; no
  local-path at all
  -> [OPEN THE SCRIPT] a genuine design difference. Phase 4 chose
     portable-by-default (local-path works on-prem) with cloud disks
     as a named upgrade. The worksheet chose cloud disks by default.
     For a lab that always runs on a cloud, the worksheet's choice is
     simpler and CNPG gets real disks without naming a class; the
     script's choice keeps `--provider=none` working unchanged.
     DECIDE ON PURPOSE when writing the hetzner branch.

* --provider=aws|azure|none case for the CSI addon
  /  hand-installed hcloud-csi
  -> no `hetzner` case exists. Section 2.

* helm_i wrapper: skip-if-installed + retry loop for small nodes
  /  plain helm install
  -> idempotency + the same etcd-stall tolerance as Step 4.5.

* metrics-server  /  not installed
  -> kubectl top; anything HPA-shaped later.

* cert-manager WITH values + Let's Encrypt/Cloudflare issuers + the
  token Secret from a local file  /  cert-manager bare
  -> the worksheet installed it only as the barman plugin's mTLS
     dependency; the script installs it as the public-TLS system for
     the Gateway. 9.2 needs the issuers.

* barman plugin v0.14.0, create-namespace guard, rollout wait
  /  same manifest by hand
  -> identical in substance. The worksheet got this one right.

* Gateway `main` from addons/gateway/gateway.yaml  /  not installed
  -> 9.2.

* Postgres/NetBox credentials from ~/.config/trk-k8s files -> Secrets
  /  `make pg-backup-secret` (new, Pulumi-sourced)
  -> same principle (secrets from local state, never git), different
     source. The new target is the better pattern for CLOUD
     credentials; files remain right for app passwords.

* ArgoCD + root app — the CNPG OPERATOR is installed by ArgoCD
  (cluster/gitops/apps/cnpg-operator.yaml), not by platform.sh
  /  CNPG operator by helm install
  -> the answer key's cluster is GitOps-managed above the platform
     layer; this one is not (yet). 9.1/9.2 should decide whether
     Hasura and the finance DB land via ArgoCD or by hand.


================================================================
2. WHAT THE HAND BUILD DID THAT THE SCRIPTS DON'T — THE HETZNER COLUMN
================================================================

Every item is a line in a future --provider=hetzner branch.
Format:  item  /  done by hand where  ->  belongs where  [status]

* ssh as root  /  typed
  -> already in the contract (sshUser); bootstrap.sh reads it; the
     Makefile was fixed 09-03.  [DONE]

* private NIC netplan patch  /  each node 09-04, worker-1 09-08
  -> infra/hetzner/main.go cloud-init user_data.
     [COMMITTED ec79742, PENDING a chosen rebuild]

* --node-ip=10.0.1.x in /etc/default/kubelet  /  end of prep, each node
  -> prep-node.sh: write KUBELET_EXTRA_ARGS from the inventory's
     privateIp (bootstrap.sh passes it as a 2nd argument). Or a
     kubeadm config with nodeRegistration.kubeletExtraArgs.node-ip.
     Harmless on one-door providers, so it can be UNCONDITIONAL.
     [TODO]

* Cilium MTU=1400  /  --set at install
  -> addons/cilium/values-hetzner.yaml merged after values.yaml;
     bootstrap.sh picks it by provider. (Could derive 1450-50 from
     /sys/class/net/enp7s0/mtu — a literal with a comment is
     clearer.)  [TODO]

* hcloud API token -> Secret kube-system/hcloud
  /  kubectl create secret --from-file
  -> platform.sh hetzner case, from ~/.config/trk-k8s/hcloud-token —
     same pattern as the Cloudflare token.  [TODO]

* hcloud-csi with storageClasses=[]  /  helm install by hand
  -> platform.sh hetzner case via helm_i.  [TODO]

* StorageClass hcloud-csi (csi.hetzner.cloud, default, WFFC,
  expandable)  /  phase9/9.0/storageclass.yaml
  -> cluster/addons/hcloud-csi/storageclass.yaml, applied by the
     hetzner case — with the default-class decision from section 1
     made explicitly.  [TODO]

* static IAM key for barman (off-AWS clusters)
  /  make persist-up + make pg-backup-secret
  -> Makefile targets — arguably right where they are, since it's
     cross-provider plumbing. platform.sh's hetzner case could call
     pg-backup-secret.  [DONE]

* ObjectStore in S3-credentials form  /  phase9/9.0/objectstore.yaml
  -> apps/postgres-cnpg/base/objectstore.yaml is Azure-form
     (inheritFromAzureAD). Needs an S3 overlay — or the base rewritten
     to S3, which is where the archive lives now regardless of
     provider.  [TODO]

* make capacity / guard / admit / the stock rule  /  Makefile
  -> [DONE]


================================================================
3. WHERE THE ANSWER KEY WAS WRONG, OR SILENT
================================================================

* azuredisk-csi-driver chart >=1.34 BREAKS platform.sh's azure case:
  the controller demands a cloud config (allowEmptyCloudConfig
  default flipped; IMDS discovery removed). The comment "needs no
  cloud-config plumbing" is no longer true.
  -> not fixed; Azure is closed. The fix, if Azure returns: a
     kube-system/azure-cloud-provider Secret built from Pulumi outputs.

* Makefile hardcoded ubuntu@ despite sshUser in the contract.
  -> fixed 09-03.

* platform.sh has no hetzner provider.
  -> section 2 is the spec.

* bootstrap.sh Step 0's lockout hint says "AWS: make check-ip &&
  make up".
  -> now `make admit`, any provider. Trivial; should be updated.

* values.yaml comment "10.0.0.0/16 on AWS and Hetzner alike".
  -> still true — and why both IPAM modes had to avoid it.

* NO knowledge anywhere of two-door providers: no node-ip, no MTU,
  no NIC readiness check.
  -> runbook 09 + docs/notes/provider-network-models.md hold the
     knowledge; section 2 is the code.

* platform.sh installs local-path as DEFAULT, so on a fresh Hetzner
  run CNPG would land on node-local disks unless a class is named.
  -> decide: keep (portable) or make the cloud CSI default whenever a
     provider is set.


================================================================
WHAT TO DO WITH THIS
================================================================

Section 2 is a work order. Smallest first:

1. prep-node.sh: write --node-ip from the inventory, unconditionally
   (one-door providers unaffected). bootstrap.sh already knows each
   node's privateIp; pass it as the second argument.

2. addons/cilium/values-hetzner.yaml with MTU: 1400; bootstrap.sh
   takes --provider and adds the extra -f.

3. platform.sh hetzner case: token Secret, helm_i hcloud-csi with
   storageClasses=[], apply addons/hcloud-csi/storageclass.yaml.
   Decide the default-class question while writing it.

4. apps/postgres-cnpg/base/objectstore.yaml -> S3 form; the Azure
   form goes to git history with the era.

5. Fix the Step 0 hint. Add the chart-break note to platform.sh's
   azure comment.

Then a rebuild on a day `make capacity` says yes —
`make up FORCE=1` (cloud-init fix lands), `make bootstrap`,
`make platform` — is the test of all of it. It should end with
ContinuousArchiving=True and no hand-typed command.
