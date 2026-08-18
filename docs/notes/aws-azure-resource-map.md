# AWS ⇄ Azure resource map — every resource, and the Kubernetes concern it serves

Written 2026-08-17, during the third provider swap (ADR 011), with both
programs open side by side: `infra/aws/main.go` (15 resources) and
`infra/azure/main.go` (14 resources) plus each provider's durable half
(`infra/aws-persistent/` stack; `infra/azure/foundation.sh`).

The organizing question is not "what does each cloud call it" but **which
part of Kubernetes needs it to exist**. Kubernetes itself only ever sees
the result: machines that can reach each other, an apiserver port, an
identity on the metadata service, and an object store for backups.
Everything below is scaffolding for one of those.

## 1 · The machines — where kubelet lives

| Concern | AWS | Azure |
|---|---|---|
| The VM | `ec2.Instance` ×3 | `compute.VirtualMachine` ×3 |
| Machine size | `t3a.medium` (2 vCPU burstable, ~$0.045/hr) | `D2als_v7` (2 vCPU, ~$0.085/hr — no burstable SKU was purchasable; see the three-layer quota model, ADR 009) |
| OS image | `LookupAmi` — a query for Canonical's latest Ubuntu 24.04 amd64 | `ImageReference` — publisher/offer/sku/`latest`, no lookup step |
| OS disk | `RootBlockDevice` inline: 20 GB gp3 (3000 IOPS baseline) | `OsDisk`: 64 GB Premium_LRS P6 — StandardSSD has no latency SLA and etcd fsyncs every write; the 2026-08-17 bring-up dropped two ~1MB helm writes before the upgrade (ADR 011 era). `DeleteOption: Delete` so `destroy` doesn't orphan disks |
| SSH login | `ec2.KeyPair` resource + AMI convention (`ubuntu` user) | inline `LinuxConfiguration.Ssh` public key — no keypair object exists; `AdminUsername: ubuntu` chosen deliberately so the contract's `sshUser` stays identical |

**For Kubernetes:** this is the kubelet's host. Nothing at this layer knows
Kubernetes exists — which is the point of the `nodes` contract. The disk
sizes matter to k8s in one place: container images + local-path PVs live on
the root disk.

The structural difference: AWS's instance is one resource that *implies*
its networking; Azure decomposes it — VM, NIC, and public IP are **three
explicit resources** wired by ID. Neither is better; Azure makes you see
the plumbing AWS hides.

## 2 · Node addressing — what the certs and peers depend on

| Concern | AWS | Azure |
|---|---|---|
| Private IP | `PrivateIp` pinned on the instance | `PrivateIPAllocationMethod: Static` on the NIC |
| Public IP | auto-assigned at launch (ephemeral — changes on stop/start) | `network.PublicIPAddress` ×3, **Standard SKU + Static** (Basic was retired Sept 2025; Dynamic would change on every deallocate) |

**For Kubernetes:** the private IPs (10.0.1.10/11/12) are load-bearing:
they're in the apiserver certificate SANs, the etcd peer list, and every
kubeconfig — that's why both providers pin them statically and the address
plan never changes across clouds. The public IPs are only for the admin
path (SSH, kubectl from the laptop, Cloudflare A record); the cluster
itself never uses them. AWS teaches this the hard way — a stop/start hands
you a new public IP and a dead kubeconfig (`make kubeconfig` re-fetches);
on Azure we bought our way out with Static allocation.

## 3 · The network fabric — etcd peers, kubelet API, the CNI overlay

| Concern | AWS | Azure |
|---|---|---|
| Address space | `ec2.Vpc` 10.0.0.0/16 | `network.VirtualNetwork` 10.0.0.0/16 |
| Node subnet | `ec2.Subnet` 10.0.1.0/24, `MapPublicIpOnLaunch` | `network.Subnet` 10.0.1.0/24 — a separate resource, NOT inline on the VNet (inline + separate declarations fight over the same child and churn every `up`) |
| Internet path | `ec2.InternetGateway` + `ec2.RouteTable` + `RouteTableAssociation` — three resources for "0.0.0.0/0 goes out" | none — implicit routing and default outbound access; the subnet just works |
| Node ↔ node | explicit SG rule: `Self: true`, all protocols | **absent by design** — Azure's built-in `AllowVnetInBound` (priority 65000) already permits all intra-VNet traffic |

**For Kubernetes:** everything cluster-internal rides this: etcd peering
(2379/2380), the kubelet API (10250), the apiserver↔kubelet path, and
Cilium's VXLAN overlay between nodes. The lesson encoded in the last row:
on AWS, forgetting the self-rule breaks *joins* (kubeadm join hangs); on
Azure the platform's default already allows it. Same requirement, opposite
defaults — the kind of asymmetry the inventory contract exists to absorb.

## 4 · The edge — who may reach the cluster at all

| Concern | AWS | Azure |
|---|---|---|
| Firewall object | `ec2.SecurityGroup` on the instances | `network.NetworkSecurityGroup` on the **subnet** |
| Rule model | unordered set; direction/protocol inferred from the ingress block | every rule spells out direction, access, protocol, and a **priority** (100–4096, lower wins) |
| Rules | 22, 6443, 30080, 30443 — all `from $myIp/32` only | identical four, priorities 100/110/120/130 |
| Egress | explicit allow-all rule | default outbound allow |

**For Kubernetes, port by port:**
- **22** — not Kubernetes at all: `bootstrap.sh` and the runbooks
- **6443** — kube-apiserver; kubectl, kubeadm join, and every controller
- **30080/30443** — the Gateway API data path: Cilium's Envoy runs
  `hostNetwork` on these ports (ADR 005), so "ingress" here is a firewall
  rule to node ports, not a cloud load balancer
- admin-IP scoping is why `check-ip` exists: when the laptop's IP drifts,
  every rebuild locks itself out at "wait for SSH"

## 5 · Node identity — pods calling cloud APIs with no secrets in the cluster

| Concern | AWS | Azure |
|---|---|---|
| Identity object | `iam.Role` + `iam.InstanceProfile` (two resources; the profile is EC2's adapter for roles) | user-assigned managed identity `id-trk-k8s-node` — created by **foundation.sh, not the ephemeral stack** |
| Backup-store grant | `RolePolicyAttachment` of the customer-managed policy the persistent stack exports (via StackReference) | `Storage Blob Data Contributor` scoped to the `pg-backups` container — granted by foundation.sh |
| Wired to VMs | `IamInstanceProfile` on the instance | `UserAssignedIdentities` by resource ID from stack config |
| Delivery to pods | IMDS: **IMDSv2 required, hop limit 3** — Cilium's overlay adds node stack + pod veth, and hop limit 2 was one too few (Hubble showed TTL-exceeded drops) | Azure IMDS — worked unmodified from pods |
| Consumers | EBS CSI driver (`AmazonEBSCSIDriverPolicy`), CNPG barman (`inheritFromIAMRole`) | CNPG barman (`inheritFromAzureAD`), Azure Disk CSI addon |

**For Kubernetes:** this is how in-cluster components (CSI drivers, barman
inside the Postgres pods) call cloud APIs using the *machine's* identity —
zero credential Secrets. The shared trade-off (ADR 007): node-scoped
identity means **any pod on the node** can reach the backup store; the
per-ServiceAccount fixes (IRSA / Workload Identity) both need an OIDC
issuer kubeadm doesn't publish.

The placement asymmetry is a scar, not a style choice: Azure's identity
lives in the *persistent* group because a `CanNotDelete` lock blocks
deleting role assignments scoped inside it — an ephemeral stack owning the
grant can never be destroyed (409 ScopeLocked, ADR 009 addendum 2). Rule
extracted: **identity that grants access to durable data lives with the
data**. AWS never forced the issue, but the persistent stack owning the
*policy* while the ephemeral stack owns only the *attachment* follows the
same rule.

## 6 · The durable half — what `make destroy` must not touch

| Concern | AWS | Azure |
|---|---|---|
| Boundary mechanism | a **second Pulumi stack** (`infra/aws-persistent`, stack `prod`) — a convention: destroy just doesn't target it | a **resource group + CanNotDelete lock** — platform-enforced: even a mistaken delete is refused |
| Backup store | S3 bucket `trk-k8s-pg-backups`: versioning on, lifecycle rules (abort stale multiparts, expire old versions), no ForceDestroy | blob container `pg-backups` in storage account `sttrkk8sf92a7ab3`: versioning + 30d soft delete |
| Cross-half link | ephemeral stack reads the policy ARN via `StackReference` — `make up` fails until `make persist-up` has run once | ephemeral stack reads `nodeIdentityId` etc. from committed stack config — valid across rebuilds because foundation names are **hashed from the subscription id** (ADR 011) |

**For Kubernetes:** this is where CNPG's `barmanObjectStore` points — WAL
archiving and base backups, the thing that makes Postgres data survive the
cluster (drill 3 proved etcd snapshots don't cover PV data; 7.1 proved
`destroy` takes the database with it). Proof it works: the AWS bucket
survived an account *suspension* with 9 backups intact (ADR 010).

## 7 · IaC state and secrets — the layer under everything

| Concern | AWS | Azure |
|---|---|---|
| Pulumi backend | S3 `tkahng-pulumi-state` | `azblob://pulumi-state` in the persistent storage account |
| Secrets provider | passphrase file on the laptop | Key Vault key `pulumi-secrets` (`azurekeyvault://…`) — nothing unrecoverable on the laptop |
| Automation identity | your SSO user (profile `personal-admin`) | service principal `sp-trk-k8s-pulumi` (Contributor + RBAC Admin + KV Crypto User), loaded by `pulumi.sh` per call |

Not a Kubernetes concern at all — but it decides what a teardown costs.
The Azure exit had to delete this layer to reach $0, which is why every
Azure return pays the `foundation.sh` + `stack init` toll (and why
`stack init` needs `--secrets-provider` as a flag; the config-file line
isn't read at init time).

## 8 · What we deliberately do NOT create — and which Kubernetes gap that leaves

| Absent resource | Why | What fills the gap |
|---|---|---|
| Managed k8s (EKS/AKS) | the entire point of the project | kubeadm |
| Cloud load balancer | no cloud-controller-manager in core (ADR 003) — `type: LoadBalancer` stays `<pending>` forever | Gateway API on hostNetwork :30080/:30443 + Cloudflare A record |
| NAT gateway | nodes sit in a public subnet with public IPs; egress is direct | SG/NSG admit only the admin IP inbound |
| Cloud DNS zone | domain lives at Cloudflare | cert-manager DNS-01 via Cloudflare token; manual A-record repoint per rebuild |
| Bastion / VPN | learning cluster, single admin | SSH from `$myIp/32` only |

## The shape of the difference, in one paragraph

AWS *infers*: one instance resource implies its NIC and public IP, security
rules imply direction and ordering, internet egress needs explicit
gateway+route plumbing. Azure *declares*: NIC, public IP, rule priorities,
and identity are all first-class objects you wire together — but routing,
egress, and intra-VNet traffic come free. Kubernetes never notices either
way, because the only surface it touches is the `nodes` contract — the
same five fields, three swaps in a row.
