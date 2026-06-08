# Terraform - Azure Deployment

Terraform alternative for Ansible phases 2 and 3. Uploads STIG+FIPS-hardened
RHEL VHD images to Azure and optionally deploys test VMs for compliance
verification.

Phases 0 (builder VMs) and 1 (image builds) remain Ansible-only since they
require local libvirt and imperative image-builder workflows.

## Prerequisites

- Built VHD files in `../output/` (produced by Ansible phases 0-1)
- An Azure service principal with Contributor access to the target resource group
- Your `.env` file configured with Azure credentials (same file used by Ansible)

If running outside the container you also need Terraform >= 1.5, `azcopy`, and
Python 3 with `azure-storage-blob`.

## Quick Start

The project-root `run.sh` handles Terraform the same way it handles Ansible — 
inside a Podman container with all tools pre-installed. Authentication is
read from `.env` automatically (`AZURE_CLIENT_ID` maps to `ARM_CLIENT_ID`, etc.).

```bash
# From the project root:
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars with your resource group, subscription, etc.

./run.sh terraform init
./run.sh terraform plan
./run.sh terraform apply
```

### Running without the container

If you prefer to run Terraform directly on your host:

```bash
cd terraform/
export ARM_CLIENT_ID="$AZURE_CLIENT_ID"
export ARM_CLIENT_SECRET="$AZURE_PASSWORD"
export ARM_TENANT_ID="$AZURE_TENANT"
export ARM_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION"

terraform init && terraform apply
```

## Resources

### Phase 2: Storage and Gallery

| Resource | Name |
|----------|------|
| Storage account | Auto-derived or `storage_account_name` |
| Blob container | `vhds` (default) |
| Page blobs | `rhel9-azure-stig-fips.vhd`, `rhel10-azure-stig-fips.vhd` |
| Compute Gallery | `stig_images` |
| Image definitions | `rhel9-stig-fips`, `rhel10-stig-fips` |
| Image versions | `1.0.0` |

### Phase 3: Test VMs (optional, `deploy_test_vms = true`)

| Resource | Name |
|----------|------|
| Virtual network | `stig-test-vnet` (10.0.0.0/16) |
| Subnet | `default` (10.0.1.0/24) |
| NSG | `stig-test-nsg` (SSH inbound) |
| Public IPs | `rhel9-stig-test-pip`, `rhel10-stig-test-pip` |
| NICs | `rhel9-stig-test-nic`, `rhel10-stig-test-nic` |
| VMs | `rhel9-stig-test`, `rhel10-stig-test` |

FIPS, LVM, and OpenSCAP STIG scans run after VM boot. Reports land in `output_dir`.

## Upload-Only (Skip Test VMs)

```bash
terraform apply -var="deploy_test_vms=false"
```

## Cleanup

```bash
./run.sh terraform destroy    # from project root
# or: terraform destroy       # if running directly
```

## Variable Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `subscription_id` | (required) | Azure subscription ID |
| `resource_group_name` | (required) | Pre-existing resource group |
| `location` | `eastus` | Azure region |
| `storage_account_name` | auto | Storage account name |
| `storage_container_name` | `vhds` | Blob container name |
| `vhd_dir` | `../output` | Path to built VHDs |
| `gallery_name` | `stig_images` | Compute Gallery name |
| `image_version` | `1.0.0` | Gallery image version |
| `deploy_test_vms` | `true` | Deploy test VMs |
| `vm_size` | `Standard_D2s_v6` | Test VM size |
| `admin_username` | `azureuser` | Test VM admin user |
| `output_dir` | `../output` | STIG report output path |

## Remote State

For shared state, uncomment the `backend "azurerm"` block in `versions.tf`.
