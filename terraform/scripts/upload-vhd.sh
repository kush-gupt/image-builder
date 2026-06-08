#!/usr/bin/env bash
# Upload a VHD as a page blob via azcopy.
# Called by Terraform null_resource with these env vars:
#   STORAGE_ACCOUNT_NAME, STORAGE_ACCOUNT_KEY, CONTAINER_NAME,
#   VHD_PATH, BLOB_NAME
set -euo pipefail

if [[ ! -f "$VHD_PATH" ]]; then
  echo "ERROR: VHD not found at $VHD_PATH" >&2
  exit 1
fi

command -v azcopy >/dev/null 2>&1 || {
  echo "ERROR: azcopy is not installed or not in PATH" >&2
  exit 1
}

export AZCOPY_AUTO_LOGIN_TYPE=AZCLI 2>/dev/null || true
export AZCOPY_CONCURRENCY_VALUE="${AZCOPY_CONCURRENCY_VALUE:-AUTO}"

SAS=$(python3 -c "
from datetime import datetime, timedelta, timezone
from azure.storage.blob import generate_container_sas, ContainerSasPermissions
sas = generate_container_sas(
    account_name='${STORAGE_ACCOUNT_NAME}',
    container_name='${CONTAINER_NAME}',
    account_key='${STORAGE_ACCOUNT_KEY}',
    permission=ContainerSasPermissions(read=True, write=True, create=True),
    expiry=datetime.now(timezone.utc) + timedelta(hours=4),
)
print(sas)
")

DEST_URL="https://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net/${CONTAINER_NAME}/${BLOB_NAME}?${SAS}"

echo "Uploading ${VHD_PATH} -> ${STORAGE_ACCOUNT_NAME}/${CONTAINER_NAME}/${BLOB_NAME}"
azcopy copy "$VHD_PATH" "$DEST_URL" --blob-type PageBlob --overwrite true --block-size-mb 64
echo "Upload complete."
