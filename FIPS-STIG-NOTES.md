# FIPS and STIG Implementation Notes

Technical decisions and trade-offs for building FIPS-enabled, STIG-hardened RHEL images for Azure.

## Builder VM Configuration

The builder VMs run in FIPS mode with the STIG profile applied at install time. Cryptographic operations during image composition (package signature verification, checksums) use FIPS-validated modules, and the `image-builder` CLI on RHEL 10 won't emit warnings about non-FIPS hosts.

### SSH Access

STIG disables password authentication and root login. The builder VMs use key-only SSH:

- `00-create-build-vms.yml` generates an ECDSA-384 keypair at `builder_key`/`builder_key.pub`
- The public key is injected into `/home/builder/.ssh/authorized_keys` during kickstart `%post`
- The `builder` user has NOPASSWD sudo (`/etc/sudoers.d/builder`)
- `PermitRootLogin no` and `PasswordAuthentication no` are set in `/etc/ssh/sshd_config.d/99-builder.conf`
- Serial console is available via `console=ttyS0,115200n8` in the kernel cmdline

### Builder vs Output Disk Layout


|           | Builder VM                                                                       | Output Azure Image                                                                       |
| --------- | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Layout    | Single root LV (maximizes build space)                                           | Separate STIG mounts (`/home`, `/tmp`, `/var`, `/var/log`, `/var/log/audit`, `/var/tmp`) |
| Size      | 120 GB                                                                           | Defined by `[[customizations.filesystem]]`                                               |
| Rationale | osbuild-composer can use 60+ GB in `/var/lib/osbuild-composer/` during a compose | STIG requires separate partitions for mount options and resource exhaustion prevention   |


## FIPS Mode

### `fips=1` Kernel Argument

Per RHEL documentation:

> "The only correct way to switch the system to FIPS mode is to enable it during the RHEL installation. Add the `fips=1` option to the kernel command line at the start of the system installation."

RHEL 10 removed `fips-mode-setup`. Post-install FIPS enablement is unsupported. `fips=1` at install time is the only method.

For builder VMs, FIPS is enabled at two levels:

1. Installer kernel: `fips=1` via `virt-install --extra-args` (Anaconda runs in FIPS mode)
2. Installed system: `bootloader --append="fips=1"` in kickstart

For output images: `[customizations] fips = true` in the blueprint (Image Builder handles kernel cmdline).

LUKS disk encryption uses PBKDF2 (FIPS-approved) when installed in FIPS mode, but Argon2 (non-FIPS) otherwise. A non-FIPS installation may be unbootable when later switched to FIPS.

### Build-Time Key Generation

SSH host keys and AIDE databases created during image build use FIPS-validated cryptography because the builder itself is in FIPS mode. Output images ship with compliant initial keys.

### `--ignore-warnings` Flag (RHEL 10)

The `image-builder` CLI warns when a non-FIPS host builds a FIPS image. Our builder VMs are FIPS-enabled so this shouldn't fire, but `--ignore-warnings` is kept as a safety net for edge cases around kernel vs userspace FIPS state during early boot.

## STIG Profile

### Why `%post` Remediation Instead of `%addon com_redhat_oscap`

`%addon com_redhat_oscap` works when the installer is NOT in FIPS mode (e.g., `bootloader --append="fips=1"` only). When the installer kernel itself boots with `fips=1`, the addon hangs during profile evaluation (likely restricted hash algorithms blocking OpenSCAP content processing).

Our approach uses `%post` remediation:

```bash
oscap xccdf eval --remediate \
    --profile xccdf_org.ssgproject.content_profile_stig \
    /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml || true
```

This runs after FIPS libraries are initialized in the installed userspace, avoids the hang, and applies the same profile/datastream as the addon.

The output Azure images use Image Builder's `[customizations.openscap]` section instead, which handles STIG application internally.

### Controls Requiring Post-Deploy Action


| Control                       | Why                                    | Fix                                         |
| ----------------------------- | -------------------------------------- | ------------------------------------------- |
| Banner text (V-230225)        | Site-specific                          | Configure `/etc/issue` and `/etc/issue.net` |
| Password aging (V-230332-337) | No local users at build time           | Applied when users are created              |
| Audit log forwarding          | Site-specific rsyslog target           | Configure `/etc/rsyslog.d/`                 |
| NTP servers                   | Site-specific                          | Configure `/etc/chrony.conf`                |
| USB authorization             | May conflict with Azure serial console | Evaluate `usbguard` rules per environment   |


### Azure Serial Console

Azure serial console operates via the hypervisor's virtual COM port, transparent to the guest. STIG's masking of `debug-shell.service` and enabling of `usbguard` do not affect it.

## RHEL 9 vs RHEL 10


|                  | RHEL 9                                  | RHEL 10                                                         |
| ---------------- | --------------------------------------- | --------------------------------------------------------------- |
| Image Builder    | `osbuild-composer` + `composer-cli`     | `image-builder` CLI (standalone)                                |
| Daemon           | `osbuild-composer.socket`               | None (runs directly)                                            |
| FIPS standard    | 140-2                                   | 140-3                                                           |
| STIG datastream  | `ssg-rhel9-ds.xml`                      | `ssg-rhel10-ds.xml`                                             |
| Build invocation | `composer-cli compose start <name> vhd` | `image-builder build vhd --blueprint <file> --output-dir <dir>` |
| Output location  | `/var/lib/osbuild-composer/artifacts/`  | Specified via `--output-dir`                                    |
| Install source   | DVD ISO (`cdrom` in kickstart)          | DVD ISO (`cdrom` in kickstart)                                  |


## Known Issues and Workarounds

### `fapolicyd` Blocks `libc.so.6` on First Boot

**Symptom:** VM boots but all services fail with "Operation not permitted" on `libc.so.6`. Cloud-init, waagent, sshd, NetworkManager never start. Azure reports `OSProvisioningTimedOut`.

**Root cause:** STIG remediation during image build modifies the RPM database (installs/configures packages). `fapolicyd`'s trust database (`trustdb`) is built from `rpmdb` at package install time but doesn't get refreshed after STIG remediation runs. On first boot, `fapolicyd` enforces against a stale trustdb that's missing entries for files modified during remediation.

**Reference:** [RHEL 9.6 Known Issues — "Missing files in trustdb cause denials for fapolicyd"](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/9.6_release_notes/known-issues)

**Fix:** Add a systemd drop-in that refreshes the trustdb before enforcement:

```toml
[[customizations.directories]]
path = "/etc/systemd/system/fapolicyd.service.d"
ensure_parents = true

[[customizations.files]]
path = "/etc/systemd/system/fapolicyd.service.d/10-update-trustdb.conf"
data = "[Service]\nExecStartPre=/usr/sbin/fapolicyd-cli --update\n"
```

This affects both RHEL 9 and RHEL 10 when using STIG profiles with `fapolicyd` enabled.

### Builder VM Disk Space

`osbuild-composer` (RHEL 9) stores compose artifacts in `/var/lib/osbuild-composer/artifacts/` and output VHDs in `/var/tmp/`. Two completed composes can consume 110+ GB. The builder VM disk should have breathing room, like 200 GB, and old artifacts should be cleaned between runs:

```bash
sudo composer-cli compose delete <old-compose-id>
sudo rm -f /var/tmp/*-disk.vhd
```

### `fips-mode-setup` Removed in RHEL 10

RHEL 10 no longer ships `fips-mode-setup`. Verify FIPS via `/proc/sys/crypto/fips_enabled` only. The `update-crypto-policies --show` command still works on both versions.

## Verification

```bash
cat /proc/sys/crypto/fips_enabled          # expect: 1
update-crypto-policies --show              # expect: FIPS
mount | grep -E '/(home|tmp|var|var/log|var/log/audit|var/tmp) '
cat /proc/cmdline | grep -o 'fips=1'

sudo oscap xccdf eval \
  --profile xccdf_org.ssgproject.content_profile_stig \
  --report /tmp/stig-report.html \
  --results /tmp/stig-results.xml \
  /usr/share/xml/scap/ssg/content/ssg-rhel$(rpm -E %rhel)-ds.xml
```

## Test Results (2026-06-08)


|                | RHEL 9.8               | RHEL 10.2              |
| -------------- | ---------------------- | ---------------------- |
| FIPS           | Enabled                | Enabled                |
| LVM partitions | 7/7                    | 7/7                    |
| STIG pass      | 440                    | 460                    |
| STIG fail      | 13                     | 13                     |
| Compliance     | 97.1%                  | 97.3%                  |
| Azure Agent    | Ready (2.15.2.1)       | Ready (2.15.2.1)       |
| VM Size        | Standard_D2s_v6 (NVMe) | Standard_D2s_v6 (NVMe) |


