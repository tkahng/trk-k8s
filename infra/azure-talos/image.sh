#!/usr/bin/env bash
# Phase 8 — put a Talos Linux disk image into Azure. ONE TIME per Talos
# version; idempotent, so re-running is a no-op.
#
# Azure has no Talos marketplace or community-gallery image (checked
# 2026-08-28: the release's cloud-images.json has zero azure entries), and
# the GitHub release ships no azure-*.vhd asset either — image generation
# moved to the **Image Factory**. So the path is: fetch a VHD from the
# factory, decompress, upload as a page blob, and create a managed image
# from it.
#
# The image lands in rg-trk-k8s-persistent — the CanNotDelete-locked group
# that already holds Pulumi state and the Postgres backups. That is
# deliberate: `make destroy` must never take the image with it, or every
# rebuild pays a ~1 GB download again (ADR 008's boundary, applied to a
# new kind of artifact).
set -euo pipefail

CONF="$HOME/.config/trk-k8s/azure-foundation.env"
[ -f "$CONF" ] || { echo "missing $CONF — run infra/azure/foundation.sh first" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

TALOS_VERSION="${TALOS_VERSION:-v1.13.9}"
# The factory's default schematic: stock Talos, no system extensions. A
# different schematic ID here = a different image (e.g. with drivers or
# extra tools baked in) without changing anything else in this script.
SCHEMATIC="${TALOS_SCHEMATIC:-376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba}"
CONTAINER="talos-images"
BLOB="talos-${TALOS_VERSION}-amd64.vhd"
IMAGE_NAME="talos-${TALOS_VERSION}-amd64"
LOCATION="${TRK_LOCATION:-eastus}"
WORK="${TMPDIR:-/tmp}/trk-talos"

echo "### Talos image ${TALOS_VERSION} -> Azure managed image '${IMAGE_NAME}'"

if az image show -g "$TRK_RG_PERSIST" -n "$IMAGE_NAME" > /dev/null 2>&1; then
  echo "  managed image already exists — nothing to do"
  az image show -g "$TRK_RG_PERSIST" -n "$IMAGE_NAME" --query id -o tsv
  exit 0
fi

KEY="$(az storage account keys list -n "$TRK_SA_NAME" -g "$TRK_RG_PERSIST" --query '[0].value' -o tsv)"
az storage container create --name "$CONTAINER" --account-name "$TRK_SA_NAME" \
  --account-key "$KEY" --only-show-errors > /dev/null
echo "  container $CONTAINER ready"

if az storage blob exists -c "$CONTAINER" -n "$BLOB" --account-name "$TRK_SA_NAME" \
     --account-key "$KEY" --query exists -o tsv | grep -q true; then
  echo "  blob $BLOB already uploaded"
else
  mkdir -p "$WORK"
  URL="https://factory.talos.dev/image/${SCHEMATIC}/${TALOS_VERSION}/azure-amd64.vhd.xz"
  echo "  downloading $URL"
  curl -fL --progress-bar "$URL" -o "$WORK/${BLOB}.xz"
  echo "  decompressing (the VHD must be uploaded RAW — Azure cannot read .xz)"
  xz -d -f "$WORK/${BLOB}.xz"
  # A VHD must be uploaded as a PAGE blob: Azure managed images are built
  # from fixed-format VHDs, and a block blob is rejected at image creation.
  echo "  uploading as page blob (~1 GB)"
  az storage blob upload --account-name "$TRK_SA_NAME" --account-key "$KEY" \
    -c "$CONTAINER" -n "$BLOB" -f "$WORK/${BLOB}" --type page --overwrite \
    --only-show-errors > /dev/null
  rm -f "$WORK/${BLOB}"
  echo "  uploaded"
fi

BLOB_URL="https://${TRK_SA_NAME}.blob.core.windows.net/${CONTAINER}/${BLOB}"
echo "  creating managed image from $BLOB_URL"
az image create -g "$TRK_RG_PERSIST" -n "$IMAGE_NAME" --source "$BLOB_URL" \
  --os-type Linux --hyper-v-generation V2 -l "$LOCATION" --only-show-errors > /dev/null

IMAGE_ID="$(az image show -g "$TRK_RG_PERSIST" -n "$IMAGE_NAME" --query id -o tsv)"
echo ""
echo "### done. Set this as the stack's talosImageId:"
echo "  $IMAGE_ID"
