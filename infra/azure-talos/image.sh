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
# The gallery exists for ONE reason: a managed image built from a VHD is
# SCSI-only, and every VM family we have quota for (D*_v7) is NVMe-ONLY.
# Azure rejects the pairing with "cannot boot with OS image or disk ...
# check disk controller types". A managed image has no way to declare NVMe
# support; a GALLERY image definition does, via --features. So the gallery
# is the bridge between a 2018-shaped disk image and 2026-shaped hardware.
# (The SCSI-capable alternatives in eastus are all confidential-compute or
# GPU families — every one of them at zero quota.)
GALLERY="sigtrkk8s"
IMAGE_DEF="talos"
IMAGE_VER="${TALOS_VERSION#v}"
LOCATION="${TRK_LOCATION:-eastus}"
WORK="${TMPDIR:-/tmp}/trk-talos"

echo "### Talos image ${TALOS_VERSION} -> Azure managed image '${IMAGE_NAME}'"

if az sig image-version show -g "$TRK_RG_PERSIST" -r "$GALLERY" \
     -i "$IMAGE_DEF" -e "$IMAGE_VER" > /dev/null 2>&1; then
  echo "  gallery image version already exists — nothing to do"
  az sig image-version show -g "$TRK_RG_PERSIST" -r "$GALLERY" -i "$IMAGE_DEF" \
    -e "$IMAGE_VER" --query id -o tsv
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

echo "### publishing into a compute gallery (so the image can declare NVMe)"
az sig create -g "$TRK_RG_PERSIST" --gallery-name "$GALLERY" -l "$LOCATION" \
  --only-show-errors > /dev/null 2>&1 || true
az sig image-definition create -g "$TRK_RG_PERSIST" --gallery-name "$GALLERY" \
  --gallery-image-definition "$IMAGE_DEF" --publisher siderolabs --offer talos \
  --sku amd64 --os-type Linux --hyper-v-generation V2 \
  --features "DiskControllerTypes=SCSI,NVMe" -l "$LOCATION" \
  --only-show-errors > /dev/null 2>&1 || true
echo "  image definition ready (DiskControllerTypes=SCSI,NVMe)"

MANAGED_ID="$(az image show -g "$TRK_RG_PERSIST" -n "$IMAGE_NAME" --query id -o tsv)"
echo "  creating gallery image version $IMAGE_VER (a few minutes)"
az sig image-version create -g "$TRK_RG_PERSIST" --gallery-name "$GALLERY" \
  --gallery-image-definition "$IMAGE_DEF" --gallery-image-version "$IMAGE_VER" \
  --managed-image "$MANAGED_ID" -l "$LOCATION" \
  --target-regions "$LOCATION" --replica-count 1 --only-show-errors > /dev/null

IMAGE_ID="$(az sig image-version show -g "$TRK_RG_PERSIST" -r "$GALLERY" \
  -i "$IMAGE_DEF" -e "$IMAGE_VER" --query id -o tsv)"
echo ""
echo "### done. Set this as the stack's talosImageId:"
echo "  $IMAGE_ID"
