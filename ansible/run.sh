#!/bin/bash
# run.sh — Run ansible-playbook inside a containerized environment
#
# Wraps ansible-playbook in a podman container built from ./Containerfile.
# The container provides ansible-core, libvirt-client, virt-install, azure-cli,
# and required collections without polluting the host.
#
# Usage:
#   ./run.sh site.yml
#   ./run.sh 00-create-build-vms.yml
#   ./run.sh 01-build-images.yml -e "rhel9_builder_ip=192.168.122.x"
#   ./run.sh 02-azure-upload.yml
#   ./run.sh 03-azure-test.yml
set -euo pipefail

IMAGE_NAME="image-builder-tools"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if ! command -v podman &>/dev/null; then
    echo "ERROR: podman is required but not found." >&2
    exit 1
fi

if ! virsh -c "${LIBVIRT_DEFAULT_URI:-qemu:///system}" uri &>/dev/null 2>&1; then
    echo "ERROR: cannot connect to libvirt at ${LIBVIRT_DEFAULT_URI:-qemu:///system}." >&2
    echo "Start the daemon:" >&2
    echo "  Fedora 41+/Bluefin: sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket" >&2
    echo "  RHEL/CentOS:        sudo systemctl enable --now libvirtd" >&2
    exit 1
fi

if ! podman image exists "${IMAGE_NAME}" 2>/dev/null; then
    echo "==> Building ${IMAGE_NAME} container image..."
    podman build -t "${IMAGE_NAME}" -f "${SCRIPT_DIR}/Containerfile" "${SCRIPT_DIR}"
fi

# --- Host-side ACLs for qemu ---
_set_qemu_acl() {
    local perm="$1" path="$2"
    setfacl -m "u:qemu:${perm}" "$path" 2>/dev/null || true
}

_set_traversal_acls() {
    local target="$1"
    local dir
    dir="$(dirname "$target")"
    while [ "$dir" != "/" ]; do
        _set_qemu_acl x "$dir"
        dir="$(dirname "$dir")"
    done
}

mkdir -p "${PROJECT_DIR}/output" "${PROJECT_DIR}/disks"
_set_traversal_acls "${PROJECT_DIR}"
_set_qemu_acl x "${PROJECT_DIR}"
_set_qemu_acl rwx "${PROJECT_DIR}/disks"
_set_qemu_acl rwx "${PROJECT_DIR}/output"

# Set ACLs on ISO paths if provided via .env
if [ -f "${PROJECT_DIR}/.env" ]; then
    # shellcheck source=/dev/null
    source "${PROJECT_DIR}/.env"
fi
for iso_var in RHEL9_ISO RHEL10_ISO; do
    iso_path="${!iso_var:-}"
    if [ -n "$iso_path" ] && [ -f "$iso_path" ]; then
        _set_traversal_acls "$iso_path"
        _set_qemu_acl r "$iso_path"
    fi
done

# Collect ISO mount args
ISO_MOUNT_ARGS=()
for iso_var in RHEL9_ISO RHEL10_ISO; do
    iso_path="${!iso_var:-}"
    if [ -n "$iso_path" ] && [ -f "$iso_path" ]; then
        _iso_dir="$(dirname "$iso_path")"
        ISO_MOUNT_ARGS+=(-v "${_iso_dir}:${_iso_dir}:ro")
    fi
done

# Collect env vars to pass
ENV_ARGS=()
for var in RHEL9_ISO RHEL10_ISO RH_ORG_ID RH_ACTIVATION_KEY BUILDER_PASSWORD \
           AZURE_CLIENT_ID AZURE_PASSWORD AZURE_TENANT AZURE_SUBSCRIPTION AZURE_RESOURCEGROUP \
           AZURE_LOCATION AZURE_STORAGE_ACCOUNT AZURE_STORAGE_CONTAINER \
           AZURE_VM_SIZE AZURE_ADMIN_USER \
           BUILD_VM_RAM BUILD_VM_VCPUS BUILD_VM_DISK LIBVIRT_NETWORK; do
    if [ -n "${!var:-}" ]; then
        ENV_ARGS+=(-e "${var}=${!var}")
    fi
done

TTY_FLAGS=()
if [ -t 0 ]; then
    TTY_FLAGS=(-it)
fi

exec podman run --rm "${TTY_FLAGS[@]}" \
    --read-only \
    --tmpfs /tmp:rw,exec,size=1g \
    --tmpfs /root:rw,size=1g \
    --cap-drop=ALL \
    --cap-add=DAC_OVERRIDE \
    --cap-add=DAC_READ_SEARCH \
    --cap-add=FOWNER \
    --cap-add=CHOWN \
    --cap-add=KILL \
    --security-opt no-new-privileges \
    --security-opt "label=disable" \
    --pids-limit=2048 \
    --network=host \
    --userns=host \
    --user=root \
    -v "${PROJECT_DIR}:${PROJECT_DIR}" \
    -v /run/libvirt:/run/libvirt \
    "${ISO_MOUNT_ARGS[@]}" \
    -w "${PROJECT_DIR}/ansible" \
    -e LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}" \
    -e ANSIBLE_CONFIG="${PROJECT_DIR}/ansible/ansible.cfg" \
    "${ENV_ARGS[@]}" \
    "${IMAGE_NAME}" \
    ansible-playbook "$@"
