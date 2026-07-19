# 2026-07-18 — Resurrection after 3 days down: two lockouts and a fix

First rebuild after the cluster sat destroyed since the Phase 6 drills.
Goal was just "bring it back up for Phase 6.5" — instead we got a nice
lesson in what rots while a cluster is down.

## What broke

### 1. Stale Pulumi state lock
`make rebuild` failed immediately: the S3 backend still held a lock from a
`pulumi destroy` process (pid 24075) that died without releasing it.
Verified the pid was gone, then `pulumi cancel` cleared it. Stack state was
already clean (0 resources), matching 0 EC2 instances — the old destroy had
effectively finished before dying.

**Lesson:** a lock error doesn't mean an operation is running. Check the
pid in the lock message; if dead, `pulumi cancel` is safe.

### 2. Admin IP drift → locked out at "wait for SSH"
Rebuild then hung at bootstrap Step 0. All three nodes timed out on port
22 — TCP-level, so not auth. Root cause: the security group admits only
`myIp` from stack config, and our public IP had changed
(181.215.169.115 → 45.132.159.195) since the last `pulumi up`. The SG was
faithfully enforcing a stale IP.

Fix at the right layer: `pulumi config set myIp <new>/32 && pulumi up`
(1 resource updated, 8s). No manual SG edits, no drift between state and
reality.

**Lesson:** `myIp` gates SSH *and* 6443 *and* the NodePorts. IP drift is
a guaranteed recurring failure for anyone on a residential/roaming
connection — it will happen again, so it must be checked mechanically,
not remembered.

### 3. Self-inflicted: two bootstraps at once
While the original `make rebuild` was still blocked in its SSH retry
loop, we launched a second `make bootstrap` in the background. Fixing the
SG unblocked *both*; two `prep-node.sh` runs then fought over apt/dpkg
locks on every node and the background one failed loudly. The foreground
run recovered because prep-node.sh is idempotent — rerunning apt steps
converged once the lock contention passed.

**Lesson:** one driver at a time. A "stuck" run that's actually in a
retry loop will resume the moment you fix the blocker — don't start a
second run alongside it. (Also: the idempotency work from Phase 6 paid
for itself today.)

## The process fix

- New `make check-ip` target: compares the live public IP
  (checkip.amazonaws.com) against stack config `myIp`; on drift it
  updates the config and says so. Skips gracefully if the IP service is
  unreachable.
- Wired as a prerequisite of `make up`, so `rebuild` gets it for free.
  `set-myip` kept as an alias for muscle memory.
- `bootstrap.sh` Step 0 timeout message now hints at the IP-drift cause
  instead of failing mutely.

Tested both paths: matching IP (no-op) and simulated drift (config
auto-healed).

## Rebuild result

- 3 nodes Ready, v1.36.2, zero non-running pods
- ArgoCD `hello` Synced/Healthy
- Cloudflare `*.k8s.kahng.dev` A record updated to new cp IP
  (44.199.247.237) — still a manual step
- cert-manager re-issued the Let's Encrypt cert via DNS-01 in ~90s;
  `https://hello.k8s.kahng.dev:30443/` → HTTP 200 with a verified cert

## Follow-ups

- The Cloudflare A-record update is the last manual step in a rebuild —
  candidate for automation (external-dns, or a small script hitting the
  CF API with the existing token).
- Next: Phase 6.5 (Gateway API migration).
