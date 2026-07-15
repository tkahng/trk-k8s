# Reverse proxies and ingress: nginx vs traefik vs caddy vs envoy

A reverse proxy accepts client connections and forwards to backends. An
ingress controller = reverse proxy + a control loop that rewrites proxy
config from Kubernetes objects. The engines differ by *configuration
philosophy*:

| Engine | Philosophy | In k8s |
|---|---|---|
| nginx | config file + reload; battle-tested C | ingress-nginx — WAS the lingua franca; **retired March 2026** |
| Traefik | born-dynamic, CRDs, no reloads | k3s default; pragmatic modern middle |
| Caddy | automatic-HTTPS champion (standalone) | niche in k8s — cert-manager already covers its magic |
| Envoy | live gRPC config API (xDS), zero reloads | never run directly: engine inside Istio, Contour, Envoy Gateway, **Cilium** |
| HAProxy | raw-throughput heritage | solid, less mindshare |

## The 2026 situation

ingress-nginx went EOL **March 2026** (announced 2025-11-11; kubernetes.io
blog). Cause: ~2 volunteers vs endless backlog, plus the
`configuration-snippet` annotation (arbitrary nginx config injection from
any Ingress) being a standing security liability. The flexibility that made
it popular is what killed it.

The successor is not another controller but a different API: **Gateway
API** (Gateway/HTTPRoute — typed resources instead of annotation soup,
role-separated ownership). `ingress2gateway` converts existing Ingresses.

## This cluster

We installed ingress-nginx in Phase 5 for its ubiquity — an already-retired
project (recommendation made without checking; caught in review 2026-07-15).
Acceptable as a teaching artifact behind a locked firewall; a finding
anywhere real.

**Planned lab (pre-capstone):** Cilium is a conformant Gateway API
implementation using the cilium-envoy DaemonSet already on every node →
enable `gatewayAPI` in cilium values, migrate hello to HTTPRoute, uninstall
ingress-nginx. One less component; the ecosystem-convergent API; the
capstone lands on the future-proof path.
