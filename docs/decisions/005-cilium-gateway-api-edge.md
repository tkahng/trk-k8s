# ADR 005 — Cilium Gateway API as the edge (and kube-proxy replacement)

Date: 2026-07-18. Status: accepted, implemented (Phase 6.5).

## Context

ingress-nginx — our Phase 5 edge — was retired upstream March 2026
(docs/notes/reverse-proxies.md). The ecosystem's successor is not another
ingress controller but a different API: **Gateway API** (typed
Gateway/HTTPRoute resources, role-separated ownership). The Phase 7
capstone should land on the future-proof path, not a dead project.

## Decision

1. **Cilium is the Gateway API implementation.** It is a conformant
   implementation driving the cilium-envoy DaemonSet already present on
   every node — the edge becomes zero additional components, versus
   adding Envoy Gateway/Traefik/Contour alongside the CNI.
2. **kube-proxy replacement on.** Cilium's Gateway API requires
   `kubeProxyReplacement=true`, so the "replace kube-proxy" lab moved
   from someday to prerequisite. eBPF service translation replaces
   iptables; kubeadm init now skips the kube-proxy addon, and Cilium
   gets `k8sServiceHost` (the real API server address) from the
   inventory, because without kube-proxy nobody provides the in-cluster
   Service VIP during agent bootstrap.
3. **hostNetwork mode for listeners.** Envoy binds the Gateway's
   listener ports (the same 30080/30443 nginx used) directly on every
   node. This is the Gateway-API-era successor to ADR 003's
   fixed-NodePort tactic: no cloud LB, no MetalLB, identical on-prem —
   and URLs/firewall rules survived the migration unchanged.
4. **One wildcard cert at the Gateway.** cert-manager's gateway-shim
   issues `*.k8s.kahng.dev` via DNS-01 from a single annotation on the
   Gateway. TLS moved from per-app Ingress config to infra — apps now
   own only an HTTPRoute (hostname + backend), which is exactly the
   role separation Gateway API was designed for.

## Consequences

- Rebuild parity: Gateway API CRDs (v1.4.1 standard) must be installed
  **before** Cilium starts — encoded in bootstrap.sh, ahead of the helm
  install.
- The kubeadm runbook (02) has one provider-agnostic deviation from
  upstream defaults: `--skip-phases=addon/kube-proxy`.
- Known quirk: in hostNetwork mode the Gateway reports
  `PROGRAMMED=False ("waiting for address")` while serving fine — there
  is no LoadBalancer Service to copy an address from. Verify by curl.
- New apps get HTTPS for free under the wildcard: HTTPRoute + DNS name,
  nothing else.
