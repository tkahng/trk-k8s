# Phase 7.5 scope — NetBox as the capstone

Researched 2026-08-01, all facts verified against live registries and
charts that day. Candidate survey, the decision, and the lab plan.

## The decisive filter: does the app need VANILLA Postgres?

The capstone exists to put a real application on the CNPG platform
adopted in ADR 007. Any app shipping its own patched Postgres defeats
that — you'd either build a custom CNPG-compatible image (an
image-building lesson, not a Kubernetes one) or bypass CNPG entirely.

Two popular candidates fail here:

- **Supabase** — not an app but a *Postgres distribution* plus ~10
  services. Needs extensions absent from CNPG images (`pg_graphql`,
  `pgsodium`, `pg_net`, `wrappers`, `supautils`), specific
  `shared_preload_libraries`, and its own role/schema bootstrap. Also
  ~10 services, several JVM/BEAM-shaped, on 3× 4 GB nodes.
- **Immich** — pins
  `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0` for
  image embeddings. Same trap, less obvious: 109k stars makes it look
  like the safe "real app" pick.

Everything below runs on plain Postgres.

## Candidates considered

| App | What it is | Postgres + | Official chart | Weight |
|---|---|---|---|---|
| **NetBox** | IPAM/DCIM — network source of truth | Valkey | ✅ 8.3.46 / v4.6.7 | light-mid |
| Saleor | E-commerce, GraphQL | Valkey | ❌ compose only | mid |
| Gitea | Git hosting | optional cache | ✅ 12.7.0 / 1.27.0 | light |
| Authentik | Identity / SSO | Redis | ✅ 2026.5.6 | mid (Django) |
| Zitadel | Identity | none | ✅ | light-mid (Go) |
| Outline | Team wiki | Redis + S3 | community | mid |
| Mastodon | Federated social | Redis + Sidekiq + S3 | community | heavy |
| Plausible | Analytics | **+ ClickHouse** | community | mid |
| Miniflux | RSS | none | community | featherweight |

Near-misses worth recording: **Gitea** would let ArgoCD pull from a repo
hosted inside the cluster it deploys — delightful circularity and a real
bootstrapping trap (destroy the cluster, lose the source of truth).
Fascinating side-lab, terrible capstone. **Authentik/Zitadel** would put
SSO in front of ArgoCD and Hubble — real platform value, but no
worker/queue topology. **Saleor** wins on topology richness and
hand-written-manifest practice if that's ever the goal.

## Why NetBox wins

1. **It documents the cluster it runs on.** IPAM/DCIM means the data is
   your own VPC, subnets, nodes and addresses — data you'd be annoyed to
   lose. That matters enormously for **Phase 8**, whose premise is
   rebuild-with-real-data-at-stake. A demo shop full of fake products is
   throwaway; an inventory of your actual infrastructure is not. It
   turns "rehearse a restore" into "actually need one".
2. **Clean external-database support**: `externalDatabase` with
   `existingSecretName` / `existingSecretKey` — maps straight onto
   CNPG's generated `pg-app` Secret with no glue.
3. **It still teaches the new things**: Django migrations, a separate RQ
   worker Deployment, a housekeeping CronJob, and *two distinct* cache
   roles the chart models explicitly (`tasksDatabase` vs
   `cachingDatabase`).
4. Second time consuming a public Helm chart through ArgoCD —
   reinforces the pattern invented for the CNPG operator.

## Chart facts verified (2026-08-01)

- `https://charts.netbox.oss.netboxlabs.com` → chart **8.3.46**, app
  **v4.6.7**, updated that day.
- **Bitnami dependencies are VENDORED in the packaged .tgz**
  (`netbox/charts/{common,postgresql,valkey}/`). ArgoCD never contacts
  Bitnami's paywalled OCI registry — the problem that pushed us off
  their pgbouncer image in 7.2 does not apply. Verified by unpacking.
- Defaults: `postgresql.enabled: true`, `valkey.enabled: true`,
  `replicaCount: 1`, `worker.enabled: true`.
- Workloads: main Deployment, `worker/deployment.yaml` (+ HPA + PDB),
  `cronjob.yaml` (housekeeping).
- Redis config is split: `tasksDatabase` (RQ queue) and
  `cachingDatabase` (cache) — separate hosts/DBs possible.

### Migrations: the chart has no Job and no hook

Grepping the templates for `migrate` returns **nothing**. NetBox's
container entrypoint runs migrations itself at boot and creates the admin
user from `SUPERUSER_NAME` / `SUPERUSER_EMAIL` / `SUPERUSER_PASSWORD`.

That *changes* the migration lesson rather than removing it. Instead of
"design a Job or PreSync hook", the questions become:

- With `replicaCount > 1`, do N pods race to migrate at boot? Does the
  entrypoint lock, or do concurrent Django migrations collide on the
  migration table?
- What does a rolling update do when the new image carries schema changes
  the old pods can't tolerate?
- Is app-migrates-itself better or worse than an explicit hook — and why
  do so many charts choose it?

**Deliberately unanswered here.** That's drill 2's job to discover.

## Plan

0. **Retire the hand-built `postgres` stack from the cluster** (keep it in
   git as the reference implementation per ADR 007). Two Postgres
   clusters plus NetBox on 12 GB total invites evictions.
1. `cluster/gitops/netbox-app.yaml` — ArgoCD Application sourcing the
   chart repo (the Helm-source pattern from `cnpg-operator-app.yaml`),
   pinned to chart 8.3.46.
2. Values: `postgresql.enabled=false` + `externalDatabase` pointed at
   CNPG's `pg-pooler-rw` with `existingSecretName: pg-app`. Keep the
   bundled Valkey initially — it's vendored and costs nothing extra.
   Real `requests`/`limits`, the first time this project sets them
   seriously.
3. A `netbox` database + user in CNPG. Decide: an extra database in the
   existing `pg` Cluster (cheap, shared blast radius) vs a second Cluster
   CR (clean isolation, more memory). Lean: extra database.
4. Secrets from local files via platform.sh (the 7.x pattern):
   `SUPERUSER_PASSWORD`, `SECRET_KEY`.
5. HTTPRoute `netbox.k8s.kahng.dev` under the existing wildcard cert —
   cashing the Phase 6.5 promise ("new apps get HTTPS for free").
6. Populate it with the real cluster: VPC 10.0.0.0/16, subnet
   10.0.1.0/24, the three nodes and their fixed IPs, the pod and service
   CIDRs. The data has to be worth restoring.

## Drills (what makes it a capstone, not a deployment)

1. **Failover under load** — run the 7.4 switchover while NetBox serves
   traffic. Does a Django app survive a primary swap, or does it need
   retry logic the pooler can't supply? The pooler-gap story from
   7.3/7.4, now with a real client instead of a psql loop.
2. **Migration behaviour at scale** — scale to `replicaCount: 3` and
   watch boot. See the open questions above.
3. **Cache vs queue** — kill Valkey. Cache loss should be survivable;
   queue loss drops pending jobs. Does it need persistence at all? The
   StatefulSet-vs-Deployment contrast for the third time, now with the
   chart having made the distinction explicit for us.
4. **Restore-with-app** — PITR the database from S3 and point NetBox at
   the restored cluster. Phase 8's rehearsal, with data that matters.
5. **Full rebuild** — `make destroy` → rebuild → does the documented
   cluster come back from git + S3 alone?

## Blockers to clear first

- **The backup bucket dies with `pulumi destroy`** (it lives in the node
  stack with `ForceDestroy`). Drills 4–5 and all of Phase 8 depend on it
  outliving the cluster. Needs a separate lifecycle.
- **App-of-apps** — Applications still aren't GitOps-managed (the 7.4
  part 1 incident). A fifth Application makes that worse, not better.
