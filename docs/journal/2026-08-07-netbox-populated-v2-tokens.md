# 2026-08-07 — NetBox holds its own cluster; the pepper finally explains itself

The capstone premise is now real: NetBox contains the VPC, subnets, nodes
and IPs of the cluster it runs on — 1 site, 1 cluster, 3 VMs, 4 prefixes,
6 IPs, all discovered live (inventory via `make nodes`, CIDRs from
`kubeadm-config`, region from the stack config), nothing hardcoded. Losing
this database now means losing real records, which is exactly what Phase
8's drills need.

Getting there took one authentication saga and one self-inflicted OOM.

## "Invalid v1 token", and what a pepper is actually for

`populate.sh` authenticated with the value platform.sh had stored as
`api_token` — which was the **pepper**, reused. NetBox answered
`403 {"detail": "Invalid v1 token"}`.

NetBox 4.6 redesigned API tokens:

- **v1** (legacy): a 40-char plaintext, sent as `Token <value>`. Ours was
  64 chars — invalid on length alone.
- **v2** (current): `Bearer nbt_<key>.<secret>` — a 12-char public
  identifier plus a 40-char secret. The server stores **only an HMAC of
  the secret, computed with one of `API_TOKEN_PEPPERS`**.

Which retroactively explains the pepper. Back when NetBox crash-looped
until we supplied a ≥50-char `api_token_peppers`, we treated it as an
arbitrary config hoop. It's the HMAC key that makes stored tokens
non-recoverable — a server-side secret, never a credential to present.
Reusing it *as* the credential was a category error the 403 was politely
pointing at.

## Chart lags app: the token that was never minted

The container's `super_user.py` mints the superuser's v2 token on first
boot — but only when **both** `superuser_api_token` and
`superuser_api_key` appear in `/run/secrets`. Chart 8.3.46's projected
volume maps only the token, not the key. So the guard fails silently and
a fresh cluster comes up with **no superuser token at all** — regardless
of what we put in the secret.

Fixes, in layers:

- **platform.sh** now generates `netbox-api-key` (12 chars) and
  `netbox-api-token` (40 chars) — alphanumeric only, NetBox's
  `TOKEN_CHARSET` has no base64 `+/=` — and puts both in the
  `netbox-superuser` secret. The pepper goes back to being just a pepper.
- **populate.sh** builds the Bearer header from the secret pair and
  **self-heals**: if the probe GET fails auth, it mints exactly that
  key/token pair via the ORM (`manage.py shell` over `kubectl exec -i`,
  script on stdin so the secret never appears in process args). Idempotent
  because the key is unique. When the chart catches up and projects
  `superuser_api_key`, the boot path takes over and the self-heal becomes
  a no-op.

The self-heal is what keeps drill 5 honest: a full rebuild from git can
run `populate.sh` unattended with no manual token surgery in between.

## The OOM I gave myself

Debugging the token meant running `manage.py shell` via `kubectl exec` —
which runs **inside the netbox container's cgroup**. Each Django shell is
~250Mi; alongside gunicorn the 1Gi limit blew. Symptoms, in order:

1. exec'd shells killed with exit 137 (the cgroup OOM killer picks the
   newcomer, so the *debugging tool* dies, not the app — confusing)
2. the pod crept to 977Mi and a gunicorn worker wedged mid-POST under
   memory-reclaim stall — the request had **committed to Postgres** but
   never finished its event pipeline or logged; GETs kept working
3. `pg_stat_activity` showed the smoking gun: the connection idle in
   `ClientRead` with an `extras_eventrule` SELECT as its last statement —
   the write path died between commit and event fan-out

Recovery: `kubectl delete pod`, **not** `rollout restart` — a restart
annotation is spec drift for ArgoCD's selfHeal to fight; deleting a pod
changes nothing ArgoCD owns. The idempotent GET-then-POST design then
proved itself: the re-run found the half-orphaned site row and simply
carried on.

Lesson filed: `kubectl exec` shares the container's resource limits.
Heavy debugging belongs in a separate pod (same image, own limits), or at
minimum one shell at a time with an eye on `kubectl top`.

## State

All six ArgoCD apps Synced/Healthy, NetBox populated, token flow durable
across rebuilds. Next: the five-drill capstone card — failover under
load, migrations at 3 replicas, cache-vs-queue, restore-with-app, full
rebuild from git + S3.
