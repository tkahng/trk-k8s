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

T0=$(date +%s)
declare -a REPORT=()
MANUAL=0

stage() { # stage <name> <command...>
  local name="$1"; shift
  local s=$(date +%s)
  echo ""
  echo "===== STAGE: $name ($(date -u +%H:%M:%S)) ====="
  "$@"
  local d=$(( $(date +%s) - s ))
  REPORT+=("$(printf '%-28s %4ds' "$name" "$d")")
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
echo "  manual steps: $MANUAL"
echo ""
echo "  Verify data survival: populate above should show '+' lines ONLY for"
echo "  the three NEW public IPs (they change every rebuild). Sites, cluster,"
echo "  VMs, prefixes, private IPs: all pre-existing from the archive"
echo "  bootstrap. The old era's public IPs linger as stale records — the"
echo "  honest cost of restored data meeting rebuilt infrastructure."
