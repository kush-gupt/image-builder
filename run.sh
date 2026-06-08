#!/bin/bash
# run.sh — Run Ansible or Terraform inside a hardened Podman container
#
# Wraps ansible-playbook and terraform in a container built from
# ansible/Containerfile.  Each mode gets a least-privilege container:
# Ansible runs as root with only the capabilities libvirt needs;
# Terraform runs as the invoking user with zero capabilities and
# a read-only project mount (only terraform/ and output/ are writable).
#
# Ansible usage (phases 0-3):
#   ./run.sh site.yml
#   ./run.sh 00-create-build-vms.yml -e force_recreate=true
#   ./run.sh 01-build-images.yml
#   ./run.sh 02-azure-upload.yml
#   ./run.sh 03-azure-test.yml
#
# Terraform usage (phases 2-3):
#   ./run.sh terraform init
#   ./run.sh terraform plan
#   ./run.sh terraform apply
#   ./run.sh terraform destroy
set -euo pipefail
umask 077

IMAGE_NAME="image-builder-tools"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

# ── Mode detection ────────────────────────────────────────────────

MODE="ansible"
if [ "${1:-}" = "terraform" ]; then
    MODE="terraform"
    shift
    case "${1:-}" in
        init|plan|apply|destroy|output|show|state|fmt|validate|refresh|import|graph|providers|version) ;;
        "")
            echo "ERROR: terraform subcommand required (e.g. $0 terraform plan)" >&2
            exit 1 ;;
        *)
            echo "ERROR: unknown terraform subcommand '${1}'" >&2
            exit 1 ;;
    esac
fi

if [ $# -eq 0 ]; then
    cat >&2 <<EOF
Usage:
  $0 <playbook.yml> [ansible-playbook args...]
  $0 terraform <subcommand> [terraform args...]
EOF
    exit 1
fi

# ── Dependency checks ─────────────────────────────────────────────

if ! command -v podman &>/dev/null; then
    echo "ERROR: podman is required but not found." >&2
    exit 1
fi

if [ "$MODE" = "ansible" ]; then
    if ! virsh -c "${LIBVIRT_DEFAULT_URI:-qemu:///system}" uri &>/dev/null 2>&1; then
        echo "ERROR: cannot connect to libvirt at ${LIBVIRT_DEFAULT_URI:-qemu:///system}." >&2
        echo "Start the daemon:" >&2
        echo "  Fedora 41+/Bluefin: sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket" >&2
        echo "  RHEL/CentOS:        sudo systemctl enable --now libvirtd" >&2
        exit 1
    fi
fi

# ── Source .env (with permission check) ───────────────────────────

ENV_FILE="${PROJECT_DIR}/.env"
if [ -f "$ENV_FILE" ]; then
    env_perms="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || true)"
    case "$env_perms" in
        600|640|400) ;;
        *) echo "WARNING: ${ENV_FILE} has mode ${env_perms}; recommend chmod 600" >&2 ;;
    esac
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

# ── Container image ───────────────────────────────────────────────

if ! podman image exists "${IMAGE_NAME}" 2>/dev/null; then
    echo "==> Building ${IMAGE_NAME} container image..."
    podman build -t "${IMAGE_NAME}" \
        -f "${PROJECT_DIR}/ansible/Containerfile" "${PROJECT_DIR}/ansible"
fi

# ── Secrets env-file ──────────────────────────────────────────────
# Write credentials to a temp file read by --env-file so they never
# appear in the podman CLI (visible via ps / /proc/*/cmdline).

ENV_TMPFILE="$(mktemp)"
trap 'rm -f "$ENV_TMPFILE"' EXIT INT TERM

_env() { printf '%s=%s\n' "$1" "$2" >> "$ENV_TMPFILE"; }

for var in AZURE_CLIENT_ID AZURE_PASSWORD AZURE_TENANT AZURE_SUBSCRIPTION \
           AZURE_RESOURCEGROUP AZURE_LOCATION AZURE_STORAGE_ACCOUNT \
           AZURE_STORAGE_CONTAINER AZURE_VM_SIZE AZURE_ADMIN_USER; do
    [ -n "${!var:-}" ] && _env "$var" "${!var}"
done

# ── Common container flags ────────────────────────────────────────

PODMAN_ARGS=(
    --rm
    --read-only
    --security-opt no-new-privileges
    --pids-limit=2048
    --network=host
    --env-file "$ENV_TMPFILE"
)

[ -t 0 ] && PODMAN_ARGS+=(-it)

# ── Ansible mode ──────────────────────────────────────────────────

if [ "$MODE" = "ansible" ]; then
    mkdir -p "${PROJECT_DIR}/output"

    _set_qemu_acl() {
        local perm="$1" path="$2"
        setfacl -m "u:qemu:${perm}" "$path" 2>/dev/null || true
    }
    _set_traversal_acls() {
        local target="$1" dir
        dir="$(dirname "$target")"
        while [ "$dir" != "/" ]; do
            _set_qemu_acl x "$dir"
            dir="$(dirname "$dir")"
        done
    }
    _set_traversal_acls "${PROJECT_DIR}"
    _set_qemu_acl x "${PROJECT_DIR}"
    _set_qemu_acl rwx "${PROJECT_DIR}/output"

    for var in RHEL9_ISO RHEL10_ISO RH_ORG_ID RH_ACTIVATION_KEY BUILDER_PASSWORD \
               BUILD_VM_RAM BUILD_VM_VCPUS BUILD_VM_DISK LIBVIRT_NETWORK; do
        [ -n "${!var:-}" ] && _env "$var" "${!var}"
    done
    _env LIBVIRT_DEFAULT_URI "${LIBVIRT_DEFAULT_URI:-qemu:///system}"
    _env ANSIBLE_CONFIG "${PROJECT_DIR}/ansible/ansible.cfg"

    PODMAN_ARGS+=(
        --userns=host
        --user=root
        --tmpfs "/tmp:rw,exec,size=1g"
        --tmpfs "/root:rw,size=1g"

        # Ansible's virt-install and libvirt access require these five
        # capabilities; everything else is dropped.
        --cap-drop=ALL
        --cap-add=DAC_OVERRIDE
        --cap-add=DAC_READ_SEARCH
        --cap-add=FOWNER
        --cap-add=CHOWN
        --cap-add=KILL

        # SELinux label=disable is required because the container reaches
        # into /run/libvirt and /var/lib/libvirt/images whose labels
        # (svirt_*_t, virt_image_t) would deny container_t access.
        --security-opt "label=disable"

        -v "${PROJECT_DIR}:${PROJECT_DIR}"
        -v /run/libvirt:/run/libvirt
        -v /var/lib/libvirt/images:/var/lib/libvirt/images
        -w "${PROJECT_DIR}/ansible"
    )

    for iso_var in RHEL9_ISO RHEL10_ISO; do
        iso_path="${!iso_var:-}"
        if [ -n "$iso_path" ] && [ -f "$iso_path" ]; then
            _set_traversal_acls "$iso_path"
            _set_qemu_acl r "$iso_path"
            PODMAN_ARGS+=(-v "$(dirname "$iso_path"):$(dirname "$iso_path"):ro")
        fi
    done

    CMD=(ansible-playbook "$@")
fi

# ── Terraform mode ────────────────────────────────────────────────

if [ "$MODE" = "terraform" ]; then
    mkdir -p "${PROJECT_DIR}/output" "${PROJECT_DIR}/terraform"

    _env ARM_CLIENT_ID    "${AZURE_CLIENT_ID:-}"
    _env ARM_CLIENT_SECRET "${AZURE_PASSWORD:-}"
    _env ARM_TENANT_ID    "${AZURE_TENANT:-}"
    _env ARM_SUBSCRIPTION_ID "${AZURE_SUBSCRIPTION:-}"
    _env HOME /tmp
    for var in TF_VAR_resource_group_name TF_VAR_storage_account_name TF_VAR_location \
               TF_VAR_subscription_id; do
        [ -n "${!var:-}" ] && _env "$var" "${!var}"
    done

    # --userns=keep-id maps the real user into the container at their
    # own UID (non-root).  This naturally yields zero capabilities in
    # all five fields (Inh, Prm, Eff, Bnd, Amb) — the most restricted
    # state possible.  No :U flag on volumes; the invoking user must
    # own terraform/ and output/.
    #
    # Nested user namespaces (IDE agents, some CI) can make keep-id
    # map the wrong UID.  A fast pre-flight detects this and falls
    # back to --userns=host (rootless host = still the real user).
    _userns="keep-id"
    if ! podman run --rm --userns=keep-id --cap-drop=ALL \
            --security-opt "label=disable" \
            -v "${PROJECT_DIR}/terraform:${PROJECT_DIR}/terraform:rw" \
            -w "${PROJECT_DIR}/terraform" \
            "${IMAGE_NAME}" test -w . 2>/dev/null; then
        _userns="host"
        echo "NOTE: --userns=keep-id unavailable (nested namespace?); using --userns=host" >&2
    fi

    PODMAN_ARGS+=(
        --userns="$_userns"

        # 2 GiB tmpfs: azcopy stages uploads here and HOME=/tmp
        # gives terraform a writable config directory.
        --tmpfs "/tmp:rw,exec,size=2g"
        --tmpfs "/root:rw,size=256m"

        # Zero capabilities — terraform needs none.
        --cap-drop=ALL

        # SELinux label=disable: bind-mounts from $HOME often sit on
        # btrfs subvolumes that lack usable xattr contexts.
        --security-opt "label=disable"

        # Project mounted read-only; only terraform state and output
        # directories are writable.  The explicit :rw on child mounts
        # is required — podman inherits the parent's :ro otherwise.
        -v "${PROJECT_DIR}:${PROJECT_DIR}:ro"
        -v "${PROJECT_DIR}/terraform:${PROJECT_DIR}/terraform:rw"
        -v "${PROJECT_DIR}/output:${PROJECT_DIR}/output:rw"
        -w "${PROJECT_DIR}/terraform"
    )

    CMD=(terraform "$@")
fi

# ── Launch ────────────────────────────────────────────────────────
# No exec — the EXIT trap must fire to delete the secrets temp file.
podman run "${PODMAN_ARGS[@]}" "${IMAGE_NAME}" "${CMD[@]}"
