# ADR 004: Talos considered for bootstrap — deferred

Date: 2026-07-14
Status: accepted

## Context

The manual kubeadm runbook (02) requires repetitive SSH work on every node.
Talos Linux would eliminate it: immutable, API-only OS (no SSH/shell),
declarative machine configs, `talosctl bootstrap`, trivial rebuilds, and a
*better* on-prem/portability story (same config boots anywhere). It is a
production-credible pattern, not a shortcut.

## Decision

Stay with Ubuntu + kubeadm, run the manual runbook at least once, automate
with inventory-driven bash in Phase 6. Talos remains a post-Phase-6
comparison lab.

Reasons:
- Phase 2's purpose is seeing the machinery (static pods, PKI, cgroup
  agreement, join trust handshake) — Talos performs all of it invisibly.
- Learner debuggability: on Ubuntu you can SSH in and poke (journalctl,
  crictl); Talos diagnostics go through `talosctl` and assume you already
  know what you're looking for.
- The Postgres/app end-goal (Phase 7) is bootstrap-agnostic; nothing
  downstream is blocked by this choice.

## Consequences

- Accept one evening of manual SSH typing (the point, not the price).
- Phase 6 may later *choose* Talos as the automation answer instead of bash —
  decided then, with the kubeadm experience in hand to judge what Talos hides.
