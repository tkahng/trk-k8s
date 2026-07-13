# ADR 001: CX23 x86 nodes instead of ARM (CAX11)

Date: 2026-07-13
Status: accepted

## Context

Historically Hetzner's ARM line (CAX) was the best price/performance and the default
recommendation for budget clusters. On **June 15, 2026** Hetzner adjusted prices
(https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/):

| Plan (2 vCPU / 4 GB / 40 GB) | Old €/mo | New €/mo |
|---|---|---|
| CX23 (x86 shared) | 3.99 | **5.49** |
| CAX11 (ARM) | 4.49 | **5.99** (+33%) |
| CPX22 (x86 premium) | 7.99 | **19.49** (+144%) |

The same inversion holds one tier up (CX33 €8.49 vs CAX21 €10.49). The CPX line more
than doubled and is no longer viable for a hobby cluster.

## Decision

Use **CX23** for all three nodes. Cheapest option, x86 avoids any arm64 image
compatibility concerns, and 4 GB RAM meets kubeadm's minimums (2 CPU / 2 GB for the
control plane) with headroom.

## Consequences

- Cluster must live in an EU location (Falkenstein/Nuremberg/Helsinki) — the CX
  series is not offered in US regions. Fine for a learning cluster.
- ~€18/mo + VAT for 3 nodes + IPv4s; hourly billing rewards tearing down between
  sessions.
- Revisit if Hetzner adjusts prices again — the ARM/x86 value balance has flipped
  once already.
