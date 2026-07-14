# Runbook 04 — Storage

Phase 4: portable storage first (works on any provider incl. on-prem), cloud
storage as a clearly-marked optional addon (ADR 002/003). All from the laptop.

## Background: the storage trio

- **StorageClass** — a *recipe* for making volumes ("who provisions, how").
  kubeadm ships with none: like CoreDNS-without-CNI, a PVC on a fresh
  cluster Pends forever.
- **PersistentVolumeClaim** — a *request* ("1Gi, ReadWriteOnce, please").
- **PersistentVolume** — the *fulfilled thing*, created by the provisioner.

## Part 1 — local-path-provisioner (portable) ✅ 2026-07-14

Provisions PVs as plain directories on the node's own disk
(`/opt/local-path-provisioner`). Works literally anywhere.

```sh
export KUBECONFIG=$(pwd)/kubeconfig
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.36/deploy/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### What the test exercise demonstrated

1. PVC alone → **Pending**, by design: the class uses
   `volumeBindingMode: WaitForFirstConsumer` — the volume isn't created
   until a pod schedules, so it can be created on *that pod's node*.
2. Pod consumes PVC → PV appears instantly on the pod's node; data written.
3. Delete pod, new pod with same PVC → **scheduler forces it to the same
   node** (the PV carries a hard `nodeAffinity` pin) and the data is there.
4. Same PVC + `nodeSelector` to a *different* node → Pending forever:
   `didn't match PersistentVolume's node affinity`. **This is the local
   storage trade-off**: pod deletion is survivable, node loss is not, and
   scheduling freedom is constrained by where data physically lives.

Why we care (Phase 7 foreshadowing): Patroni-style Postgres HA does
*application-level* replication precisely so each replica can use fast
node-local disks without node loss meaning data loss.

## Part 2 — EBS CSI driver (AWS-only addon) ✅ 2026-07-14

Network-attached volumes: survive node loss, follow pods across nodes
(within an AZ). The trade: AWS-only, and the driver must call the EC2 API —
so it needs AWS credentials.

### Credentials: node IAM role (no secrets in the cluster)

`infra/aws/main.go`: IAM role `k8s-node` (assumable by EC2 only) with AWS's
managed `AmazonEBSCSIDriverPolicy`, wrapped in an instance profile attached
to all three instances. The driver picks up credentials from the instance
metadata service (IMDS) — nothing stored in Kubernetes.

Two operational consequences (learned the hard way, see journal):
- **PowerUserAccess is out**: creating the role needed admin, and any future
  instance-touching `pulumi up` needs `iam:PassRole` — Pulumi (backend AND
  provider) now runs on the `personal-admin` profile.
- **IMDS hop limit must be 3, not 2**, with an overlay CNI: response TTL
  burns one hop into the node stack and one crossing Cilium into the pod
  veth. Symptom at 2: TCP connects but every data packet vanishes; Hubble
  showed `TTL exceeded DROPPED`. (Also: `HttpTokens: required` = IMDSv2.)

Also hit: the driver's Kubernetes-API metadata fallback needs
`node.spec.providerID`, which only a cloud-controller-manager sets — and we
have none (ADR 003). IMDS is therefore the only path; it has to work.

### Install

```sh
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver --namespace kube-system
kubectl apply -f cluster/addons/aws-ebs-csi/storageclass.yaml   # ebs-sc, gp3, NOT default
```

`local-path` stays the default StorageClass — cloud storage is opt-in via
`storageClassName: ebs-sc` (ADR 002: the cluster must work without it).

### What the test exercise demonstrated

Same journal-file exercise as Part 1, but: writer pod pinned to worker-1,
then reader pod pinned to **worker-2** — the case that deadlocked local-path.
With EBS the volume detached from worker-1's instance and attached to
worker-2's (~30s), data intact. `aws ec2 describe-volumes` shows it as a
real gp3 volume — `Encrypted: true` via the account-level EBS-encryption
default, zero cluster config.

Remaining EBS limit: volumes are AZ-scoped (all nodes are in us-east-1a, so
invisible here — would bite in a multi-AZ cluster).

On-prem equivalent (documented, not installed): Longhorn — replicated block
storage across node disks; same PVC interface, no cloud.
