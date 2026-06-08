# Azure RHEL Image Builder: STIG + FIPS + LVM (BYOS)

Builds hardened RHEL 9 and RHEL 10 Azure VHD images locally using Red Hat Image Builder. Output images ship with DISA STIG remediation, FIPS 140 cryptographic mode, LVM partitioning (separate STIG mount points), Azure Gen 2/UEFI support, and BYOS (no baked-in marketplace, PAYG entitlement).

## Prerequisites


| Requirement          | Details                                                               |
| -------------------- | --------------------------------------------------------------------- |
| Host OS              | Linux with KVM/libvirt (tested on Fedora 44/Bluefin)                  |
| Podman               | To run Ansible within a container                                     |
| RHEL ISOs            | RHEL 9.x DVD ISO, RHEL 10.x DVD ISO                                   |
| Red Hat subscription | Org ID + activation key for builder VM package access                 |
| Azure credentials    | Service principal with Contributor role on your target resource group |


## Quick Start

```bash
# 1. Configure
git clone https://github.com/kush-gupt/image-builder.git && cd image-builder
cp .env.example .env
# Edit .env: ISO paths, RH subscription, Azure credentials

# 2. Run the full pipeline (everything happens inside a container)
./run.sh site.yml

# Or run individual phases:
./run.sh 00-create-build-vms.yml -e force_recreate=true
./run.sh 01-build-images.yml
./run.sh 02-azure-upload.yml
./run.sh 03-azure-test.yml
```

`run.sh` builds and launches a Podman container with Ansible, Terraform, Azure CLI, `azcopy`, and libvirt tools. The host only needs `podman`, `virsh`, and `setfacl`.

## Pipeline Phases


| Phase                  | What                                       | Typical Time |
| ---------------------- | ------------------------------------------ | ------------ |
| 0                      | Provision builder VMs from DVD ISOs        | ~5 min       |
| 1                      | Build VHD images (parallel on both VMs)    | ~11 min      |
| 2                      | Upload VHDs + create Azure Compute Gallery | ~4 min       |
| 3                      | Deploy test VMs + FIPS/LVM/STIG scans      | ~7 min       |
| **Total (end-to-end)** |                                            | **~27 min**  |


### Phases 0-1: Build VHDs

You need some FIPS-enabled RHEL machine running Red Hat Image Builder. A RHEL 10 builder can produce both RHEL 9 and RHEL 10 images; RHEL 9 can only build up to RHEL 9 and below. The builder pushes TOML blueprints and outputs Azure-compatible `.vhd` files with STIG packages, FIPS kernel args, and LVM layout baked in.

We include Ansible playbooks that automate this from scratch: provision libvirt/KVM VMs from DVD ISOs (`00-create-build-vms.yml`), then run the builds (`01-build-images.yml`). If you already have a FIPS RHEL box with Image Builder, skip straight to the blueprints in `blueprints/`.

### Phases 2-3: Upload and Verify

Two options for uploading VHDs to Azure and deploying test VMs:

**Ansible** (~11 min):

```bash
./run.sh 02-azure-upload.yml    # ~4 min
./run.sh 03-azure-test.yml      # ~7 min
```

**Terraform** (~11 min):

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars (see terraform/README.md)
./run.sh terraform init
./run.sh terraform apply
```

Both paths do the same thing: upload VHDs as page blobs, publish them to an Azure Compute Gallery as Gen 2 image versions, then (optionally) deploy test VMs and run FIPS/LVM/OpenSCAP STIG scans. See `terraform/README.md` for full details.

Phase 3 checks:

- `/proc/sys/crypto/fips_enabled == 1`
- LVM volumes with STIG-required mount points
- Full OpenSCAP STIG compliance scan (HTML + XML reports)

## Environment Variables

Copy `.env.example` to `.env`. Required:


| Variable                          | Purpose                              |
| --------------------------------- | ------------------------------------ |
| `RHEL9_ISO`                       | Absolute path to RHEL 9 DVD ISO      |
| `RHEL10_ISO`                      | Absolute path to RHEL 10 DVD ISO     |
| `RH_ORG_ID` / `RH_ACTIVATION_KEY` | Red Hat subscription for builder VMs |
| `AZURE_CLIENT_ID`                 | Service principal app ID             |
| `AZURE_PASSWORD`                  | Service principal secret             |
| `AZURE_TENANT`                    | Azure AD tenant                      |
| `AZURE_SUBSCRIPTION`              | Subscription ID                      |
| `AZURE_RESOURCEGROUP`             | Target resource group                |
| `AZURE_STORAGE_ACCOUNT`           | Storage account for VHD blobs        |
| `AZURE_LOCATION`                  | Azure region (default: `eastus`)     |
| `BUILDER_PASSWORD`                | Throwaway password for builder VMs   |


Optional: `BUILD_VM_RAM` (default 4096), `BUILD_VM_VCPUS` (default 2), `BUILD_VM_DISK` (default 120).

## Output Image Filesystem Layout


| Mount Point      | Size   | STIG Rule |
| ---------------- | ------ | --------- |
| `/`              | 10 GiB | Root      |
| `/home`          | 1 GiB  | V-230328  |
| `/tmp`           | 1 GiB  | V-230295  |
| `/var`           | 3 GiB  | V-230292  |
| `/var/log`       | 1 GiB  | V-230293  |
| `/var/log/audit` | 10 GiB | V-230294  |
| `/var/tmp`       | 1 GiB  | V-230297  |


## BYOS

These images should carry no marketplace billing. Register post-deploy:

```bash
sudo subscription-manager register --org=<ORG_ID> --activationkey=<KEY>
```

## Troubleshooting

**Azure VM won't boot**: Images are published to an Azure Compute Gallery with `--feature DiskControllerTypes=SCSI,NVMe`, which enables deployment on both SCSI and NVMe VM sizes (including Dsv6). Confirm the gallery image version exists and the VM size supports Gen 2.

**STIG scan shows failures**: Some rules require site-specific config (banner text, NTP servers, audit forwarding). See `FIPS-STIG-NOTES.md` for the full list.

## Repository Structure

```
.
├── .env.example                     # Environment variables template
├── run.sh                               # Podman wrapper (entry point)
├── ansible/
│   ├── Containerfile                # Container image definition
│   ├── ansible.cfg
│   ├── site.yml                     # Full orchestrator
│   ├── 00-create-build-vms.yml      # Provision FIPS+STIG builder VMs
│   ├── 01-build-images.yml          # Build VHDs on builder VMs
│   ├── 02-azure-upload.yml          # Upload VHDs, create Azure images
│   ├── 03-azure-test.yml            # Deploy test VMs, verify compliance
│   ├── vars.yml                     # Variables (reads from env)
│   ├── inventory.yml
│   ├── requirements.yml             # Galaxy collections
│   └── tasks/
│       └── azure-verify-vm.yml      # FIPS/LVM/STIG checks per VM
├── terraform/                       # Alternative for phases 2-3
│   ├── README.md
│   ├── versions.tf, provider.tf
│   ├── variables.tf, locals.tf
│   ├── storage.tf, gallery.tf
│   ├── network.tf, test-vms.tf
│   ├── outputs.tf
│   └── scripts/
├── blueprints/
│   ├── rhel9-azure-stig-fips.toml   # RHEL 9 Image Builder blueprint
│   └── rhel10-azure-stig-fips.toml  # RHEL 10 Image Builder blueprint
├── kickstarts/
│   ├── rhel9-builder.ks.j2          # Builder VM kickstart template
│   └── rhel10-builder.ks.j2
├── FIPS-STIG-NOTES.md               # Implementation details
└── output/                          # Built VHDs and reports
```

## References

- [RHEL 9: Composing a customized RHEL system image](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/composing_a_customized_rhel_system_image/index)
- [RHEL 10: Composing a customized RHEL system image](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html-single/composing_a_customized_rhel_system_image/index)
- [RHEL 10 Security Hardening: Switching to FIPS mode](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/security_hardening/switching-rhel-to-fips-mode)
- [SCAP Security Guide](https://www.open-scap.org/security-policies/scap-security-guide/)
- [Azure Gen 2 VM Support](https://learn.microsoft.com/en-us/azure/virtual-machines/generation-2)

