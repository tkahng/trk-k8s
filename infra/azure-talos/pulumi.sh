#!/usr/bin/env bash
# pulumi, with the Azure environment already loaded.
#
# Three things have to be in the environment for every Pulumi call:
#   - the service principal (ARM_*), so Pulumi acts as automation, not as you
#   - AZURE_STORAGE_ACCOUNT + KEY, for the azblob state backend
#   - the Key Vault URL as the secrets provider (recorded in the stack)
# Sourcing two files and running an `az` lookup before every command is the
# kind of ritual that gets skipped and then debugged; this makes it structural.
#
# The storage key is fetched live rather than stored, so rotating it needs no
# edit here. Costs one `az` call per invocation.
set -euo pipefail

CONF="$HOME/.config/trk-k8s/azure-foundation.env"
SP="$HOME/.config/trk-k8s/azure-sp.env"

[ -f "$CONF" ] || { echo "missing $CONF — run infra/azure/foundation.sh first" >&2; exit 1; }
[ -f "$SP" ]   || { echo "missing $SP — run infra/azure/foundation.sh first" >&2; exit 1; }

# shellcheck disable=SC1090
. "$CONF"
# shellcheck disable=SC1090
. "$SP"

if [ -z "${AZURE_STORAGE_KEY:-}" ]; then
  AZURE_STORAGE_KEY="$(az storage account keys list \
    -n "$TRK_SA_NAME" -g "$TRK_RG_PERSIST" --query '[0].value' -o tsv)"
  export AZURE_STORAGE_KEY
fi

exec pulumi "$@"
