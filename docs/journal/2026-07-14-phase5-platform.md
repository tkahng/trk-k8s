# 2026-07-14 (night) — Phase 5: the cluster becomes useful

One session, four platform capabilities, all laptop-side:

1. **metrics-server** — `kubectl top` works. Reading: the platform stack
   alone (Cilium, Hubble, ingress, cert-manager, ArgoCD, CSI) uses ~40% of
   each 4GB node. Sizing intuition for the Phase 7 capstone.
2. **ingress-nginx** on fixed NodePorts 30080/30443 (portable, no cloud LB
   per ADR 003), SG opened from admin IP only. Hello app (traefik/whoami)
   as **Kustomize base + dev overlay** — the env-specific bits (replicas,
   host, TLS) live in the overlay; the base is environment-free. Verified
   load-balancing across 2 replicas via distinct pod hostnames per request.
3. **cert-manager + Let's Encrypt, DNS-01 on Cloudflare.** Domain decision:
   dedicated low-stakes domain (kahng.dev) over the daily-driver zone,
   because Cloudflare API tokens scope to WHOLE zones — a leaked in-cluster
   token = DNS control of everything in that zone. Cert issued in 84s;
   `https://hello.k8s.kahng.dev:30443` verifies green. Port 80 never
   opened — DNS-01 needs no inbound at all.
   - Incident: the API token got pasted into an AI-chat transcript →
     rolled. Lesson: secrets go terminal-only, and "roll" (rekey) is the
     cheap response to any suspected exposure.
4. **ArgoCD** — installed via Helm, repo access via dedicated read-only
   deploy key (GitHub enforces one-repo-per-key; "Key is already in use"
   turned out to mean the first add succeeded). `Application` in
   `cluster/gitops/hello-app.yaml` with automated sync + prune + selfHeal:
   Synced/Healthy at the pushed revision within a minute.

## The shift that matters

The hello app is no longer deployed BY anyone. Git holds the desired state;
the cluster converges to it. `kubectl apply` for that app is now drift that
selfHeal reverts. This is the operating model the rest of the project
(and Phase 7's capstone stack) builds on.

## Loose ends

- Wildcard DNS (`*.k8s.kahng.dev`) and the nip.io host both point at the
  control plane's public IP — both need updating after every rebuild.
- ArgoCD initial admin secret should be deleted after setting a real
  password.
- More addons should migrate under ArgoCD (app-of-apps pattern) in Phase 6+.
