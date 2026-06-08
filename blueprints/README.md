# Blueprints

Red Hat Image Builder blueprint files (TOML). Each one defines a full OS image: packages, filesystem layout, kernel arguments, services, and config files. Image Builder reads the blueprint, resolves dependencies, runs `osbuild`, and outputs an Azure-compatible `.vhd`.


| Blueprint                    | Builder tool                      | FIPS standard | STIG datastream     |
| ---------------------------- | --------------------------------- | ------------- | ------------------- |
| `rhel9-azure-stig-fips.toml` | `composer-cli` (osbuild-composer) | 140-3         | `ssg-rhel9-ds.xml`  |
| `rhel10-azure-stig-fips.toml` | `image-builder` CLI              | 140-3         | `ssg-rhel10-ds.xml` |


## Packages

Every package in the `[[packages]]` list exists because some STIG control requires it or Azure may need it. Grouped by purpose:


| Purpose                             | Packages                                                                                                        |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Audit (V-230386 and friends)        | `audit`, `audispd-plugins`                                                                                      |
| File integrity (V-230551)           | `aide`                                                                                                          |
| Application whitelisting (V-230523) | `fapolicyd`                                                                                                     |
| FIPS crypto                         | `dracut-fips`, `crypto-policies`, `gnutls-utils`, `nss-tools`                                                   |
| Smart card / CAC (V-230275)         | `opensc`, `pcsc-lite`, `openssl-pkcs11` (RHEL 9) / `p11-kit` (RHEL 10)                                          |
| SSH hardening                       | `openssh-server`, `openssh-clients`                                                                             |
| Firewall (V-230505)                 | `firewalld`                                                                                                     |
| USB device control (V-230524)       | `usbguard`                                                                                                      |
| Identity / auth (V-230372)          | `sssd`, `sssd-tools`                                                                                            |
| Logging                             | `rsyslog`, `rsyslog-gnutls`                                                                                     |
| Misc STIG requirements              | `chrony`, `cronie`, `postfix`, `s-nail`, `sudo`, `policycoreutils`, `policycoreutils-python-utils`, `rng-tools` |
| STIG scanning                       | `openscap-scanner`, `scap-security-guide`                                                                       |
| RHSM (BYOS registration)            | `subscription-manager`                                                                                          |


## Customizations

### Partitioning mode and supported image types

`partitioning_mode` and `[[customizations.filesystem]]` work on any image type that produces a partitioned disk. The unsupported types:

| Image type | Why |
|-----------|-----|
| `container` | No disk, just a rootfs tarball |
| `tar` | Same, no partition table |
| `image-installer` | ISO extracts a pre-installed tar via Kickstart `liveimg`. Filesystem customizations silently fail or cause Kickstart errors. |
| `edge-commit`, `edge-container` | OSTree commits with no disk image |
| `edge-installer`, `edge-simplified-installer` | OSTree install media, partition layout is fixed |

Supported types: `ami`, `gce`, `vhd`, `qcow2`, `oci`, `vmdk`, `ova`, `vagrant-libvirt`, `wsl`, `edge-raw-image`, `edge-ami`, `edge-vsphere`.

Three modes are available:

| Mode | Behavior |
|------|----------|
| `auto-lvm` | Raw partitions unless filesystem customizations exist, then LVM. Default when `[[customizations.filesystem]]` is present. |
| `lvm` | Always LVM, even with no extra mount points. Used by these blueprints. |
| `raw` | Raw partitions even with multiple mount points. |

### FIPS and STIG profile

```toml
[customizations]
fips = true
partitioning_mode = "lvm"

[customizations.openscap]
profile_id = "xccdf_org.ssgproject.content_profile_stig"
```

`fips = true` tells Image Builder to add `fips=1` to the kernel command line and include `dracut-fips` in the initramfs. The OpenSCAP section runs STIG remediation during the build, so the output image ships pre-hardened.

### Kernel arguments

```toml
[customizations.kernel]
append = "audit_backlog_limit=8192 audit=1 page_poison=1 vsyscall=none pti=on init_on_free=1"
```

- `audit=1 audit_backlog_limit=8192`: STIG requires audit from PID 1 with sufficient backlog
- `page_poison=1 init_on_free=1`: Memory corruption mitigations (V-230277, V-230279)
- `vsyscall=none`: Disables legacy vsyscall interface (V-230278)
- `pti=on`: Page table isolation against Meltdown

### LVM filesystem layout

Seven separate mount points, each required by a different STIG control to prevent resource exhaustion and enforce mount options (`noexec`, `nosuid`, `nodev`):

```toml
[[customizations.filesystem]]
mountpoint = "/"
minsize = "10 GiB"
# /home (V-230328), /tmp (V-230295), /var (V-230292),
# /var/log (V-230293), /var/log/audit (V-230294), /var/tmp (V-230297)
```

`/var/log/audit` gets 10 GiB because STIG requires retaining audit logs for extended periods and the system must halt (not overwrite) when storage is exhausted.

### Config file overrides

STIG remediation via OpenSCAP handles most controls, but a few need explicit file drops because either the remediation script doesn't cover them or the default config is wrong:


| File                                                  | STIG control                           | What it does                                                   |
| ----------------------------------------------------- | -------------------------------------- | -------------------------------------------------------------- |
| `/etc/systemd/logind.conf`                            | `logind_session_timeout`               | 30-minute idle session timeout                                 |
| `/etc/sysctl.d/99-stig-namespaces.conf`               | `sysctl_user_max_user_namespaces`      | Disables unprivileged user namespaces                          |
| `/etc/crypto-policies/back-ends/openssh.config`       | `harden_sshd_macs`                     | Restricts SSH to FIPS-approved ciphers, MACs, and key exchange |
| `/etc/crypto-policies/back-ends/opensshserver.config` | (same)                                 | Server-side counterpart                                        |
| `/root/.bash_profile`, `/root/.bashrc`                | `file_permission_user_init_files_root` | Mode 0600 on root's init files                                 |
| `/etc/sssd/sssd.conf`                                 | `sssd_enable_certmap`                  | Certificate mapping for smart card auth                        |
| `/etc/sudoers.d/99-stig-selinux`                      | `selinux_context_elevation_for_sudo`   | `use_pty`, `env_reset`, syslog                                 |


### fapolicyd trustdb workaround

Both blueprints include a systemd drop-in at `/etc/systemd/system/fapolicyd.service.d/10-update-trustdb.conf` that runs `fapolicyd-cli --update` before the daemon starts.

Without this, `fapolicyd` can block `libc.so.6` on first boot. STIG remediation during the build modifies packages after `fapolicyd`'s trust database was built from `rpmdb`, leaving the trustdb stale. The drop-in refreshes it before enforcement kicks in. See [RHEL 9.6 known issues](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/9.6_release_notes/known-issues) for details.

## Differences between RHEL 9 and RHEL 10

The RHEL 9 blueprint specifies `datastream` explicitly in the OpenSCAP section because `osbuild-composer` requires it. RHEL 10's `image-builder` CLI resolves the datastream from the profile ID automatically.

RHEL 9 uses `openssl-pkcs11` for PKCS#11 smart card support. RHEL 10 replaces it with `p11-kit`, which is the upstream successor.

Both blueprints are otherwise identical in structure and intent.

## Modifying

Fork a blueprint, change the `name` and `version`, and adjust packages or config files. Run `composer-cli blueprints push <file>` (RHEL 9) or pass the file directly to `image-builder build` (RHEL 10). See `FIPS-STIG-NOTES.md` in the repo root for build-time constraints and known issues.