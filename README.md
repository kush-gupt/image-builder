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
source .env
./ansible/run.sh site.yml

# Or run individual phases:
./ansible/run.sh 00-create-build-vms.yml -e force_recreate=true
./ansible/run.sh 01-build-images.yml
./ansible/run.sh 02-azure-upload.yml
./ansible/run.sh 03-azure-test.yml
```

`run.sh` builds and launches a Podman container with Ansible, Azure CLI, `azcopy`, and libvirt tools. The host only needs `podman`, `virsh`, and `setfacl`.

## Repository Structure

```
.
├── .env.example                     # Environment variables template
├── ansible/
│   ├── run.sh                       # Podman wrapper (entry point)
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
├── blueprints/
│   ├── rhel9-azure-stig-fips.toml   # RHEL 9 Image Builder blueprint
│   └── rhel10-azure-stig-fips.toml  # RHEL 10 Image Builder blueprint
├── kickstarts/
│   ├── rhel9-builder.ks.j2          # Builder VM kickstart Template
│   └── rhel10-builder.ks.j2
├── FIPS-STIG-NOTES.md               # Implementation details
└── output/                          # Built VHDs and reports
```

## Pipeline Phases

### Phase 0: Builder VMs

Provisions two libvirt/KVM VMs from DVD ISOs with unattended kickstart. Both VMs boot in FIPS mode and apply STIG remediation during install. SSH access uses an ECDSA-384 keypair generated at runtime.

- RHEL 9 runs `osbuild-composer` + `composer-cli`
- RHEL 10 runs the standalone `image-builder` CLI

### Phase 1: Image Build

Pushes TOML blueprints to Image Builder on each VM. Both builds run in parallel. Output is a pair of Azure-compatible `.vhd` files with STIG packages, FIPS kernel args, and LVM layout pre-configured.

### Phase 2: Azure Upload

Uploads VHDs as page blobs via `azcopy` (parallel, SAS-token authenticated), then publishes them to an Azure Compute Gallery as Gen 2 image versions.

### Phase 3: Verification

Deploys test VMs from the custom images and checks:

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

These images carry no marketplace billing. Register post-deploy:

```bash
sudo subscription-manager register --org=<ORG_ID> --activationkey=<KEY>
```

## Troubleshooting

**Azure VM won't boot**: Images are published to an Azure Compute Gallery with `--feature DiskControllerTypes=SCSI,NVMe`, which enables deployment on both SCSI and NVMe VM sizes (including Dsv6). Confirm the gallery image version exists and the VM size supports Gen 2.

**STIG scan shows failures**: Some rules require site-specific config (banner text, NTP servers, audit forwarding). See `FIPS-STIG-NOTES.md` for the full list.

## References

- [RHEL 9: Composing a customized RHEL system image](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/composing_a_customized_rhel_system_image/index)
- [RHEL 10: Composing a customized RHEL system image](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html-single/composing_a_customized_rhel_system_image/index)
- [RHEL 10 Security Hardening: Switching to FIPS mode](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/security_hardening/switching-rhel-to-fips-mode)
- [SCAP Security Guide](https://www.open-scap.org/security-policies/scap-security-guide/)
- [Azure Gen 2 VM Support](https://learn.microsoft.com/en-us/azure/virtual-machines/generation-2)

