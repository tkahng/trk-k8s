# Phase 7.5 scope — Saleor as the capstone

Researched 2026-08-01. Decision (vs Supabase) and the lab plan, before any
manifests exist.

## Why Saleor, not Supabase

Supabase is not an app that uses Postgres — it's a **Postgres
distribution** plus ~10 services layered on it (GoTrue, PostgREST,
Realtime, Storage, Kong, Studio…). Its Postgres needs extensions absent
from CNPG's images (`pg_graphql`, `pgsodium`, `pg_net`, `wrappers`,
`supautils`), specific `shared_preload_libraries`, and a bootstrap that
creates its own roles/schemas. That leaves two bad options: build a
custom image marrying `supabase/postgres` with CNPG's instance manager
(days of extension compilation — an *image-building* lesson, not a
Kubernetes one), or run Supabase's own Postgres as a plain StatefulSet,
in which case the capstone never touches the platform Phase 7.4 adopted.
Plus ~10 services (several JVM/BEAM-shaped) on 3× 4 GB nodes that
already spend ~40% each on the platform stack.

Saleor consumes CNPG exactly as intended: it wants a `DATABASE_URL`, and
CNPG's generated `pg-app` Secret already ships a ready-made connection
URI. Everything from 7.4 — pooler, failover, WAL archiving — ends up
protecting a real application.

## What's actually out there (verified on GHCR, 2026-08-01)

| Component | Image | Notes |
|---|---|---|
| API | `ghcr.io/saleor/saleor:3.23.23` | Django + GraphQL; released 2026-07-31 |
| Worker | same image | different command (celery) |
| Dashboard | `ghcr.io/saleor/saleor-dashboard:3.23.20` | static SPA on :80 |
| Cache/broker | `valkey/valkey:8.1-alpine` | **Valkey, not Redis** — upstream moved after the license change |

**There is no official Helm chart** (`saleor-platform` is a
docker-compose repo with no releases; zero helm repos in the org). So we
hand-write Kustomize manifests — which matches this project's style
anyway, and mirrors how 7.1–7.3 were built.

Reference topology and config come from `saleor-platform`'s
`docker-compose.yml` + `common.env` + `backend.env`.

## Config surface to translate

    DATABASE_URL=postgres://user:pass@host/db   <- CNPG pg-app Secret (has a uri key)
    CACHE_URL=redis://cache:6379/0              <- valkey Service, db 0
    CELERY_BROKER_URL=redis://cache:6379/1      <- same valkey, db 1
    SECRET_KEY=changeme                         <- generate; local file -> Secret (7.x pattern)
    ALLOWED_HOSTS=...                           <- Django; must include our hostname
    DASHBOARD_URL=...
    EMAIL_URL / DEFAULT_FROM_EMAIL              <- park (no SMTP); or mailpit later
    HTTP_IP_FILTER_ENABLED=True                 <- keep True (prod recommendation)
    OTEL_* -> drop (jaeger is dev-only tracing)

Worker command (from compose, note the `-B` embedded beat scheduler):

    celery -A saleor --app=saleor.celeryconf:app worker --loglevel=info -B

## The three real design problems

These are the reasons this is a lab and not a copy-paste.

### 1. The shared media volume — our RWO storage can't do it

Compose shares `saleor-media:/app/media` between **api and worker**.
local-path is ReadWriteOnce and node-pinned (the 7.1 lesson): two pods
on different nodes cannot share it, and forcing them onto one node to
fake it would be a lie we'd have to maintain.

Options, in preference order:
1. **S3 media storage** — Saleor supports it; reuses the bucket + node
   IAM pattern from the 7.4 backup lab. Correct answer, and the same
   shape of lesson: object storage replaces shared filesystems in k8s.
2. RWX volume — we have no RWX provisioner (would mean EFS/NFS: new
   infra, real cost).
3. Pin both to one node — defeats the purpose; documents a dead end.

**Decision: S3.** Second bucket, second inline IAM policy, same
`inheritFromIAMRole`-style credential path.

### 2. Migrations — the most valuable unexplored question

Compose says "run it yourself":

    docker compose run --rm api python3 manage.py migrate
    docker compose run --rm api python3 manage.py populatedb --createsuperuser

In Kubernetes this becomes a genuine design decision, and it's the piece
of "running a database properly" that 7.1–7.4 never touched:

- **Job vs initContainer**: a Job runs once per apply; an initContainer
  runs on *every* pod start (N replicas = N concurrent migrations).
- **Ordering**: the API must not serve before the schema exists — and
  ArgoCD syncs everything at once by default.
- **Idempotency**: Django migrations are idempotent-ish, but concurrent
  runs can deadlock on the migration table.
- **ArgoCD sync-waves / hooks**: `PreSync` hook is the idiomatic answer
  — a Job that must succeed before the rest of the sync proceeds.

Planned: a `PreSync` hook Job for `migrate`, and a **separate, manually
triggered** Job for `populatedb` (sample data is a one-time act, not
desired state). Drill: delete the DB, re-sync, watch the hook rebuild
the schema.

### 3. Node budget on 4 GB × 3

Rough asks: api ~600 MB, worker ~400 MB, dashboard ~50 MB, valkey
~100 MB, plus CNPG (~300 MB × 2 instances). Platform stack already eats
~40% of each node.

**Prerequisite: retire the hand-built `apps/postgres` stack from the
cluster** (keep it in git as the reference implementation — ADR 007
says it stays for legibility, not for runtime). Running two Postgres
clusters plus five new Deployments on 12 GB total is asking for
evictions.

Also: set real `requests`/`limits` for the first time in this project.
We've mostly coasted; this forces the sizing conversation.

## Lab plan

0. Retire `postgres` (hand-built) from the cluster; keep `postgres-cnpg`.
1. Infra: media bucket + IAM policy in `infra/aws` (mirrors the backup
   bucket, incl. the same node-scoped-vs-IRSA caveat).
2. `apps/saleor/base/`: valkey (StatefulSet? see drill), API Deployment,
   worker Deployment, dashboard Deployment, Services, Secret wiring from
   CNPG's `pg-app`, `SECRET_KEY` from a local file via platform.sh.
3. Migration `PreSync` hook Job; `populatedb` as a manual Job.
4. HTTPRoutes under the existing wildcard: `shop.k8s.kahng.dev` (API) and
   `dashboard.k8s.kahng.dev` — the Phase 6.5 promise ("new apps get
   HTTPS for free") finally cashed.
5. ArgoCD Application `saleor` → `apps/saleor/overlays/dev`.

## Drills (what makes it a capstone, not a deployment)

1. **Failover under load** — run the 7.4 switchover *while Saleor serves
   traffic*. Does a real Django app survive a primary swap, or does it
   need connection-retry logic the pooler can't provide?
2. **Migration replay** — drop the schema, re-sync, watch the PreSync
   hook rebuild it before the API starts.
3. **Valkey: cache vs broker.** Losing the cache should be survivable;
   losing the broker loses queued tasks. Does it need persistence at
   all? Good forcing function for StatefulSet-vs-Deployment (the 7.2
   contrast, third time around).
4. **Restore-with-app** — PITR the database from S3 and point Saleor at
   the restored cluster. The Phase 8 rehearsal, with a real app on top.
5. **Rebuild** — `make destroy` → full rebuild → does the whole shop
   come back from git + S3 alone? (Backup-bucket lifecycle is a
   prerequisite here — see below.)

## Blockers to clear first

- **The backup bucket dies with `pulumi destroy`** (node stack,
  `ForceDestroy`). Drill 5 and all of Phase 8 depend on it outliving the
  cluster. Needs a separate lifecycle.
- **App-of-apps** — Applications still aren't GitOps-managed (7.4 part 1
  incident). Adding a fifth Application makes this more annoying, not
  less.
