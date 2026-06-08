# Demo: Verifying STIG-Compliant Azure Images

This walkthrough shows how to SSH into the deployed Azure VMs and prove they meet spec:
DISA STIG compliance, FIPS 140 cryptography, and LVM disk partitioning — all baked in at
build time by Red Hat Image Builder.

## Prerequisites

- The test VMs were deployed by `ansible/03-azure-test.yml`
- SSH key: `id_rsa_azure_test` (generated during deployment)

## Connect to the VMs

```bash
# RHEL 9
ssh -i id_rsa_azure_test azureuser@<RHEL9_VM_IP>

# RHEL 10
ssh -i id_rsa_azure_test azureuser@<RHEL10_VM_IP>
```

## 1. Verify FIPS 140 Mode

FIPS is enabled at the kernel level during image build — not bolted on after the fact.

```bash
$ cat /proc/sys/crypto/fips_enabled
1

# RHEL 9 only (fips-mode-setup was removed in RHEL 10):
$ sudo fips-mode-setup --check
FIPS mode is enabled.
```

The kernel command line confirms `fips=1` was set by Image Builder:

```bash
$ cat /proc/cmdline
# RHEL 9:  ...fips=1 boot=LABEL=boot...
# RHEL 10: ...fips=1 boot=UUID=...
```

## 2. Verify LVM Partitioning

STIG requires separate mount points for `/home`, `/tmp`, `/var`, `/var/log`,
`/var/log/audit`, and `/var/tmp`. Image Builder's `partitioning_mode = "lvm"`
with explicit `[[customizations.filesystem]]` entries ensures this at build time.

```bash
$ sudo lvs
  homelv          rootvg -wi-ao----  1.00g
  rootlv          rootvg -wi-ao---- 10.00g
  tmplv           rootvg -wi-ao----  1.00g
  var_log_auditlv rootvg -wi-ao---- 10.00g
  var_loglv       rootvg -wi-ao----  1.00g
  var_tmplv       rootvg -wi-ao----  1.00g
  varlv           rootvg -wi-ao----  3.00g

$ df -hT / /home /tmp /var /var/log /var/log/audit /var/tmp
Filesystem                         Type  Size  Used Avail Use% Mounted on
/dev/mapper/rootvg-rootlv          xfs    10G  2.2G  7.8G  22% /
/dev/mapper/rootvg-homelv          xfs   960M   40M  921M   5% /home
/dev/mapper/rootvg-tmplv           xfs   960M   40M  921M   5% /tmp
/dev/mapper/rootvg-varlv           xfs   3.0G  179M  2.8G   6% /var
/dev/mapper/rootvg-var_loglv       xfs   960M   40M  921M   5% /var/log
/dev/mapper/rootvg-var_log_auditlv xfs    10G  104M  9.9G   2% /var/log/audit
/dev/mapper/rootvg-var_tmplv       xfs   960M   40M  921M   5% /var/tmp
```

## 3. Run OpenSCAP STIG Scan

The image was built with `[customizations.openscap]` applying the STIG profile
during compose. Verify on the live system:

```bash
$ sudo oscap xccdf eval \
    --profile xccdf_org.ssgproject.content_profile_stig \
    --results /tmp/stig-results.xml \
    --report /tmp/stig-report.html \
    /usr/share/xml/scap/ssg/content/ssg-rhel$(rpm -E %rhel)-ds.xml

# Count results:
$ sudo grep -c '<result>pass</result>' /tmp/stig-results.xml
$ sudo grep -c '<result>fail</result>' /tmp/stig-results.xml
```

**Results from this build:**


| VM        | Pass | Fail | Compliance |
| --------- | ---- | ---- | ---------- |
| RHEL 9.8  | 440  | 13   | 97.1%      |
| RHEL 10.2 | 460  | 13   | 97.3%      |


The remaining 13 failures are rules that require runtime/environment context
(e.g., external log aggregation endpoints, site-specific banner text, physical
hardware controls) that cannot be satisfied in a generic image build.

## 4. Verify Azure Integration

```bash
# VM Agent is running and reporting to Azure
$ sudo systemctl status waagent
● waagent.service - Azure Linux Agent
     Active: active (running)

# Cloud-init completed provisioning
$ sudo cloud-init status
status: done

# Hyper-V daemons for host communication
$ sudo systemctl status hypervkvpd
● hypervkvpd.service - Hyper-V KVP daemon
     Active: active (running)
```

## 5. Verify Kernel Hardening

```bash
$ cat /proc/cmdline | tr ' ' '\n' | grep -E 'fips|audit|pti|vsyscall|init_on_free|audit_backlog'
fips=1                    # FIPS 140 cryptographic module enforcement
audit=1                   # Enable the kernel audit subsystem at boot
audit_backlog_limit=8192  # Queue up to 8192 audit events before dropping (prevents loss under load)
pti=on                    # Page Table Isolation — mitigates Meltdown (CVE-2017-5754)
vsyscall=none             # Disable vsyscall page — eliminates a fixed-address Return-Oriented Programming gadget target
init_on_free=1            # Zero memory pages on free — prevents use-after-free data leaks
```

## How It Works

All of this compliance is defined declaratively in a single TOML blueprint
(`blueprints/rhel{9,10}-azure-stig-fips.toml`) and applied at image build time
by Red Hat Image Builder. No post-deploy Ansible remediation needed — the image
boots compliant from the first second.

Key blueprint sections:

- `fips = true` — kernel-level FIPS
- `partitioning_mode = "lvm"` + `[[customizations.filesystem]]` — LVM layout
- `[customizations.openscap]` — STIG profile applied during compose
- `[customizations.kernel]` — hardening parameters
- `[customizations.services]` — auditd, fapolicyd, usbguard enabled at build

## Image Versions


| Image            | OS                   | Kernel                 | Build Tool            |
| ---------------- | -------------------- | ---------------------- | --------------------- |
| rhel9-stig-fips  | RHEL 9.8 (Plow)      | 5.14.0-687.12.1.el9_8  | osbuild-composer 149  |
| rhel10-stig-fips | RHEL 10.2 (Coughlan) | 6.12.0-211.20.1.el10_2 | image-builder (bootc) |


