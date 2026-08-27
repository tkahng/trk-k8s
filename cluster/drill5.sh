#!/usr/bin/env bash
# Drill 5 — the formal rebuild, measured.
#
# Run AFTER `make destroy` has completed, from the repo root:
#     cluster/drill5.sh
#
# It runs the standard bring-up (the same make targets a resume uses —
# nothing special-cased, that's the point), stopwatching every stage and
# tallying every MANUAL step. The score that matters is not the wall
# clock; it's the manual-step count. Each one is a gap in git, the
# Makefile, or platform.sh.
#
# This era's variant: apps/postgres-cnpg/base/cluster.yaml bootstraps the
# new generation FROM THE PREVIOUS GENERATION'S ARCHIVE (drill 4's
# machinery, promoted to canonical). populate.sh at the end must find
# every object already present — data survival, not re-discovery.
set -euo pipefail
cd "$(dirname "$0")/.."

# PRECONDITION: the infrastructure must actually be GONE. The first attempt
# (2026-08-27) measured nothing: `make up` reported "14 unchanged" and
# bootstrap reported "already initialized" because the destroy + bring-up
# had happened by hand before the harness ran. Every stage was an
# idempotent no-op and the numbers were meaningless. A measurement harness
# that cannot detect its own precondition produces confident nonsense, so
# check it here rather than trust the operator's memory.
echo "===== PRECONDITION: infrastructure must be destroyed ====="
existing="$(cd infra/azure && ./pulumi.sh stack --show-name >/dev/null 2>&1 && ./pulumi.sh stack output nodes 2>/dev/null || true)"
if [ -n "$existing" ]; then
  echo "  REFUSING: the stack still has resources. Run 'make destroy' first," >&2
  echo "  then re-run this harness in the same session." >&2
  exit 1
fi
echo "  stack is empty — this will be a real rebuild"

T0=$(date +%s)
declare -a REPORT=()
MANUAL=0
FAILED=0

stage() { # stage <name> <command...>
  local name="$1"; shift
  local s=$(date +%s)
  echo ""
  echo "===== STAGE: $name ($(date -u +%H:%M:%S)) ====="
  # Never let a failing stage kill the run before the scorecard prints:
  # attempt 1 lost every measurement because populate.sh exited non-zero
  # under `set -e` and the report never reached the terminal. A failed
  # stage is DATA — record it and continue.
  if "$@"; then
    local d=$(( $(date +%s) - s ))
    REPORT+=("$(printf '%-28s %4ds' "$name" "$d")")
  else
    local d=$(( $(date +%s) - s ))
    REPORT+=("$(printf '%-28s %4ds  ** FAILED **' "$name" "$d")")
    FAILED=$((FAILED+1))
  fi
}

manual() { # manual <description>  — waits for operator, counts against us
  MANUAL=$((MANUAL+1))
  local s=$(date +%s)
  echo ""
  echo "===== MANUAL STEP #$MANUAL: $1"
  read -rp "      press enter when done... "
  local d=$(( $(date +%s) - s ))
  REPORT+=("$(printf '%-28s %4ds  (MANUAL)' "$1" "$d")")
}

wait_green() {
  export KUBECONFIG="$PWD/kubeconfig"
  until [ "$(kubectl -n argocd get applications --no-headers 2>/dev/null | grep -c 'Synced.*Healthy')" = "6" ]; do sleep 15; done
  until kubectl -n postgres-cnpg get cluster pg -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}' 2>/dev/null | grep -q True; do sleep 15; done
}

stage "make up"        make up
stage "make bootstrap" make bootstrap
stage "make platform"  make platform
manual "Cloudflare A record -> new cp-1 IP (make nodes shows it)"
stage "converge: 6 apps + archiving" wait_green
stage "populate (must be verification-only)" ./apps/netbox/populate.sh

echo ""
echo "==================== DRILL 5 SCORE ===================="
for r in "${REPORT[@]}"; do echo "  $r"; done
echo "  ------------------------------------------"
printf '  %-28s %4ds\n' "TOTAL" $(( $(date +%s) - T0 ))
echo "  manual steps:   $MANUAL"
echo "  failed stages:  $FAILED"
echo ""
echo "  populate above shows what the rebuild did NOT carry: with an empty"
echo "  bootstrap every object is recreated (all '+' lines) — the platform"
echo "  survives in git, the DATA survives only because populate rediscovers"
echo "  it. To make the data itself survive, bootstrap the new generation"
echo "  from the previous one's archive (apps/postgres-cnpg/drill4-pg-restore.yaml"
echo "  is the reference) — that variant is its own lab."
