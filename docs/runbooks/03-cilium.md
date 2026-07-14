# Runbook 03 — Install Cilium (CNI)

Takes the Phase 2 cluster from NotReady to Ready. Runs entirely from the
laptop — no SSH needed (first taste of "the cluster is the API").

Prereqs: runbook 02 done (3 nodes NotReady), `make kubeconfig` fetched,
`brew install helm cilium-cli`.

## Why the nodes are NotReady

The kubelet reports NotReady until a CNI plugin provides pod networking.
Control-plane pods run anyway (host network); CoreDNS sits Pending because it
needs a *pod* IP. Installing the CNI resolves both.

## Install

Values live in `cluster/addons/cilium/values.yaml`. The non-negotiable one:

- `clusterPoolIPv4PodCIDRList: [10.244.0.0/16]` — must match kubeadm's
  `--pod-network-cidr` and must NOT overlap the node network. Cilium's
  default pool is 10.0.0.0/8, which contains our 10.0.0.0/16 VPC — leaving
  the default would hand pods addresses that collide with machines.

Also enabled: Hubble relay + UI (observability). Deliberately default:
kube-proxy stays (replacement is a later lab), vxlan tunnel routing (portable
across providers — no cloud route tables involved).

```sh
export KUBECONFIG=$(pwd)/kubeconfig
helm repo add cilium https://helm.cilium.io/
helm repo update
helm install cilium cilium/cilium --version 1.19.4 \
  --namespace kube-system -f cluster/addons/cilium/values.yaml
```

## Verify

```sh
kubectl wait --for=condition=Ready node --all --timeout=300s
cilium status --wait          # everything OK
kubectl get pods -A -o wide   # CoreDNS now Running, with 10.244.x.x pod IPs
```

The full end-to-end suite (deploys probe workloads, ~10 min, then cleans up;
requires 2+ workers):

```sh
cilium connectivity test
```

## Explore Hubble (flow observability)

```sh
cilium hubble ui        # port-forwards and opens the UI in the browser
```

Or the CLI stream: `cilium hubble port-forward &` then `hubble observe`.

## Upgrade/change values later

```sh
helm upgrade cilium cilium/cilium --version <v> -n kube-system \
  -f cluster/addons/cilium/values.yaml
```

## Rebuild note

After a full cluster rebuild (runbooks 02 → 03), this runbook is just the
`helm install` + verify again — the values file is the durable artifact.
