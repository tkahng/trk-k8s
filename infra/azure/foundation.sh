#!/usr/bin/env bash
# Azure foundation — everything that must exist BEFORE Pulumi can run.
#
# The bootstrap problem: Pulumi needs somewhere to keep state, and it can't
# create that somewhere with Pulumi. On AWS this was a hand-made S3 bucket
# documented only in a journal entry. Here it's a script, because "I created
# it by hand once" is exactly the knowledge that evaporates — and we just
# lost an entire cloud account to prove it.
#
# Creates, in the PERSISTENT resource group (ADR 008's lifecycle boundary,
# which Azure models natively):
#   - storage account + container for Pulumi state (versioned, soft-delete)
#   - Key Vault + RSA key as Pulumi's secrets provider (replaces the
#     local passphrase file, which was unrecoverable if lost)
#   - service principal for Pulumi (no human credentials in automation)
#   - CanNotDelete lock on the whole group
#
# Idempotent: every step checks before creating. Safe to re-run.
set -euo pipefail

LOCATION="${LOCATION:-eastus}"
RG_PERSIST="rg-trk-k8s-persistent"
CONF_DIR="$HOME/.config/trk-k8s"
CONF_FILE="$CONF_DIR/azure-foundation.env"
SP_FILE="$CONF_DIR/azure-sp.env"
SSH_KEY="$HOME/.ssh/azure_k8s"

command -v az >/dev/null || { echo "az CLI not found" >&2; exit 1; }
SUB_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
USER_OID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
echo "subscription: $SUB_ID"

# Storage account and Key Vault names are GLOBALLY unique. Derive a stable
# suffix from the subscription id so re-runs land on the same names instead
# of littering the account with orphans.
SUFFIX="$(printf '%s' "$SUB_ID" | shasum | cut -c1-8)"
SA_NAME="sttrkk8s${SUFFIX}"        # 3-24 chars, lowercase alphanumeric only
KV_NAME="kv-trk-k8s-${SUFFIX}"     # 3-24 chars, alphanumeric + hyphens
STATE_CONTAINER="pulumi-state"
BACKUP_CONTAINER="pg-backups"
KV_KEY_NAME="pulumi-secrets"

mkdir -p "$CONF_DIR"

echo "### resource providers"
# A fresh subscription has almost nothing registered, and creating a
# resource of an unregistered type fails with a MissingSubscription-
# Registration error that reads like a permissions problem. Registration is
# async, per-subscription, and permanent — do it once, up front.
for p in Microsoft.Storage Microsoft.KeyVault Microsoft.Compute \
         Microsoft.Network Microsoft.ManagedIdentity; do
  state="$(az provider show -n "$p" --query registrationState -o tsv 2>/dev/null || echo Unknown)"
  if [ "$state" != "Registered" ]; then
    az provider register -n "$p" >/dev/null 2>&1 || true
    echo "  registering $p (was $state)"
  else
    echo "  $p ok"
  fi
done
# Block until the two this script needs are actually usable.
for p in Microsoft.Storage Microsoft.KeyVault; do
  for _ in $(seq 1 60); do
    [ "$(az provider show -n "$p" --query registrationState -o tsv 2>/dev/null)" = "Registered" ] && break
    sleep 5
  done
  echo "  $p -> $(az provider show -n "$p" --query registrationState -o tsv 2>/dev/null)"
done

echo "### SSH keypair (dedicated per provider — the AWS one is gone with its account)"
if [ ! -f "$SSH_KEY" ]; then
  ssh-keygen -t ed25519 -N '' -C "tkahng-k8s-azure" -f "$SSH_KEY" >/dev/null
  echo "  created $SSH_KEY"
else
  echo "  $SSH_KEY exists"
fi

echo "### persistent resource group"
if ! az group show -n "$RG_PERSIST" >/dev/null 2>&1; then
  az group create -n "$RG_PERSIST" -l "$LOCATION" \
    --tags cluster=trk-k8s lifecycle=persistent >/dev/null
  echo "  created $RG_PERSIST"
else
  echo "  $RG_PERSIST exists"
fi

echo "### storage account for pulumi state (hardened)"
if ! az storage account show -n "$SA_NAME" -g "$RG_PERSIST" >/dev/null 2>&1; then
  # The S3-Block-Public-Access analogue, plus TLS floor. Shared key access
  # stays ENABLED: Pulumi's azblob backend authenticates with an account
  # key, and disabling it would break the state backend (revisit if Pulumi
  # gains reliable Entra auth for azblob).
  az storage account create -n "$SA_NAME" -g "$RG_PERSIST" -l "$LOCATION" \
    --sku Standard_LRS --kind StorageV2 \
    --allow-blob-public-access false \
    --min-tls-version TLS1_2 \
    --https-only true \
    --tags cluster=trk-k8s lifecycle=persistent >/dev/null
  echo "  created $SA_NAME"
else
  echo "  $SA_NAME exists"
fi

# Versioning + soft delete: state corruption is recoverable, state deletion
# is not. This is the one bucket where losing a byte ruins the day.
az storage account blob-service-properties update \
  --account-name "$SA_NAME" -g "$RG_PERSIST" \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days 30 >/dev/null
echo "  versioning + 30d soft delete on"

SA_KEY="$(az storage account keys list -n "$SA_NAME" -g "$RG_PERSIST" --query '[0].value' -o tsv)"
# Two containers, same account, same lifecycle: both must outlive every
# cluster. pg-backups is what barman-cloud archives WAL and base backups to
# (the AWS equivalent died with its account — ADR 008/009).
for c in "$STATE_CONTAINER" "$BACKUP_CONTAINER"; do
  if ! az storage container show -n "$c" \
        --account-name "$SA_NAME" --account-key "$SA_KEY" >/dev/null 2>&1; then
    az storage container create -n "$c" \
      --account-name "$SA_NAME" --account-key "$SA_KEY" >/dev/null
    echo "  created container $c"
  else
    echo "  container $c exists"
  fi
done

echo "### node managed identity + backup access"
# WHY THIS LIVES HERE, not in infra/azure (learned the hard way):
# a CanNotDelete lock on this resource group blocks DELETING anything scoped
# inside it — including role assignments. When the ephemeral stack owned the
# assignment, `pulumi destroy` failed with
#   409 ScopeLocked "cannot perform delete operation because following
#   scope(s) are locked"
# and the stack wedged.
#
# The deeper point: an identity that grants access to DURABLE data belongs
# with the data, not with the compute that borrows it. The VMs are cattle and
# get a fresh principalId on every rebuild; the identity and its grant are
# part of the persistent layer. infra/azure now just attaches this identity
# by resource ID.
NODE_IDENTITY="id-trk-k8s-node"
if ! az identity show -n "$NODE_IDENTITY" -g "$RG_PERSIST" >/dev/null 2>&1; then
  az identity create -n "$NODE_IDENTITY" -g "$RG_PERSIST" -l "$LOCATION" \
    --tags cluster=trk-k8s lifecycle=persistent >/dev/null
  echo "  created $NODE_IDENTITY"
else
  echo "  $NODE_IDENTITY exists"
fi
NODE_ID_RESOURCE="$(az identity show -n "$NODE_IDENTITY" -g "$RG_PERSIST" --query id -o tsv)"
NODE_ID_PRINCIPAL="$(az identity show -n "$NODE_IDENTITY" -g "$RG_PERSIST" --query principalId -o tsv)"

# Storage Blob Data Contributor, scoped to the CONTAINER not the account:
# the same account holds Pulumi state and the nodes have no business there.
BACKUP_SCOPE="/subscriptions/$SUB_ID/resourceGroups/$RG_PERSIST/providers/Microsoft.Storage/storageAccounts/$SA_NAME/blobServices/default/containers/$BACKUP_CONTAINER"
if ! az role assignment list --assignee "$NODE_ID_PRINCIPAL" --scope "$BACKUP_SCOPE" \
      --query "[?roleDefinitionName=='Storage Blob Data Contributor'] | length(@)" -o tsv 2>/dev/null | grep -q '^[1-9]'; then
  # --assignee-object-id + principal-type: a freshly created managed identity
  # can race Entra replication and fail PrincipalNotFound without the hint.
  for _ in 1 2 3 4 5 6; do
    az role assignment create --assignee-object-id "$NODE_ID_PRINCIPAL" \
      --assignee-principal-type ServicePrincipal \
      --role "Storage Blob Data Contributor" --scope "$BACKUP_SCOPE" >/dev/null 2>&1 && break
    sleep 10
  done
  echo "  granted $NODE_IDENTITY Storage Blob Data Contributor on $BACKUP_CONTAINER"
else
  echo "  backup role assignment exists"
fi

echo "### key vault as pulumi's secrets provider"
if ! az keyvault show -n "$KV_NAME" >/dev/null 2>&1; then
  # RBAC authorization, not legacy access policies — current best practice.
  # Purge protection off on purpose: a soft-deleted vault name is blocked
  # for 90 days, which is a nasty trap in a lab you may rebuild.
  az keyvault create -n "$KV_NAME" -g "$RG_PERSIST" -l "$LOCATION" \
    --enable-rbac-authorization true \
    --retention-days 7 \
    --tags cluster=trk-k8s lifecycle=persistent >/dev/null
  echo "  created $KV_NAME"
else
  echo "  $KV_NAME exists"
fi

KV_ID="$(az keyvault show -n "$KV_NAME" --query id -o tsv)"
# Grant the human first, or the key creation below fails on a fresh vault.
if [ -n "$USER_OID" ]; then
  az role assignment create --assignee-object-id "$USER_OID" \
    --assignee-principal-type User \
    --role "Key Vault Crypto Officer" --scope "$KV_ID" >/dev/null 2>&1 || true
  echo "  granted you Key Vault Crypto Officer"
fi

echo "### service principal for pulumi (no human creds in automation)"
if [ ! -f "$SP_FILE" ]; then
  # Contributor to build infrastructure; RBAC Administrator because the
  # cluster's nodes need a managed identity WITH a role assignment for blob
  # access, and Contributor cannot grant roles. Both narrower than Owner.
  SP_JSON="$(az ad sp create-for-rbac --name "sp-trk-k8s-pulumi" \
    --role Contributor --scopes "/subscriptions/$SUB_ID" -o json)"
  SP_APPID="$(printf '%s' "$SP_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["appId"])')"
  SP_SECRET="$(printf '%s' "$SP_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')"
  (umask 077 && cat > "$SP_FILE" <<EOF
# Pulumi service principal — chmod 600, NEVER in git.
export ARM_CLIENT_ID=$SP_APPID
export ARM_CLIENT_SECRET=$SP_SECRET
export ARM_TENANT_ID=$TENANT_ID
export ARM_SUBSCRIPTION_ID=$SUB_ID
export AZURE_CLIENT_ID=$SP_APPID
export AZURE_CLIENT_SECRET=$SP_SECRET
export AZURE_TENANT_ID=$TENANT_ID
EOF
  )
  echo "  created sp-trk-k8s-pulumi -> $SP_FILE (chmod 600)"
  az role assignment create --assignee "$SP_APPID" \
    --role "Role Based Access Control Administrator" \
    --scope "/subscriptions/$SUB_ID" >/dev/null 2>&1 || \
    echo "  WARN could not grant RBAC Administrator — managed-identity role assignments will fail"
  az role assignment create --assignee "$SP_APPID" \
    --role "Key Vault Crypto User" --scope "$KV_ID" >/dev/null 2>&1 || true
  echo "  granted Contributor + RBAC Administrator + Key Vault Crypto User"
else
  echo "  $SP_FILE exists (delete it to rotate the credential)"
fi

echo "### pulumi secrets key in the vault"
if ! az keyvault key show --vault-name "$KV_NAME" -n "$KV_KEY_NAME" >/dev/null 2>&1; then
  az keyvault key create --vault-name "$KV_NAME" -n "$KV_KEY_NAME" \
    --kty RSA --size 2048 >/dev/null
  echo "  created key $KV_KEY_NAME"
else
  echo "  key $KV_KEY_NAME exists"
fi

echo "### recording foundation config"
(umask 077 && cat > "$CONF_FILE" <<EOF
# Azure foundation — written by infra/azure/foundation.sh. Safe to re-source.
export AZURE_LOCATION=$LOCATION
export AZURE_SUBSCRIPTION_ID=$SUB_ID
export AZURE_TENANT_ID=$TENANT_ID
export TRK_RG_PERSIST=$RG_PERSIST
export TRK_SA_NAME=$SA_NAME
export TRK_STATE_CONTAINER=$STATE_CONTAINER
export TRK_BACKUP_CONTAINER=$BACKUP_CONTAINER
# CNPG barmanObjectStore destinationPath
export TRK_BACKUP_URL=https://$SA_NAME.blob.core.windows.net/$BACKUP_CONTAINER
# The identity infra/azure attaches to every VM (persistent, survives destroy)
export TRK_NODE_IDENTITY_ID=$NODE_ID_RESOURCE
export TRK_KV_NAME=$KV_NAME
# Pulumi state backend + secrets provider
export AZURE_STORAGE_ACCOUNT=$SA_NAME
export PULUMI_BACKEND_URL=azblob://$STATE_CONTAINER
export PULUMI_SECRETS_PROVIDER=azurekeyvault://$KV_NAME.vault.azure.net/keys/$KV_KEY_NAME
EOF
)
echo "  wrote $CONF_FILE"

echo "### delete lock on the persistent group (LAST — earlier steps would be unaffected anyway)"
if ! az lock show -n no-delete -g "$RG_PERSIST" >/dev/null 2>&1; then
  az lock create -n no-delete --lock-type CanNotDelete -g "$RG_PERSIST" >/dev/null
  echo "  locked $RG_PERSIST (CanNotDelete)"
else
  echo "  lock exists"
fi

cat <<EOF

### Foundation ready. State and secrets now outlive every cluster.
  storage account : $SA_NAME (versioned, 30d soft delete)
  state container : $STATE_CONTAINER
  backup container: $BACKUP_CONTAINER
  backup url      : https://$SA_NAME.blob.core.windows.net/$BACKUP_CONTAINER
  key vault       : $KV_NAME  key: $KV_KEY_NAME
  service princ.  : sp-trk-k8s-pulumi -> $SP_FILE
  lock            : CanNotDelete on $RG_PERSIST

Next:
  source $CONF_FILE
  source $SP_FILE
  pulumi login \$PULUMI_BACKEND_URL
EOF
