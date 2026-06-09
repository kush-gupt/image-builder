#!/usr/bin/env bash
# Verify FIPS mode, LVM layout, and STIG compliance on a deployed Azure VM.
# Called by Terraform null_resource with these env vars:
#   VM_NAME, VM_IP, SSH_KEY, ADMIN_USER, RHEL_VERSION, OUTPUT_DIR
set -euo pipefail

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
SSH_CMD="ssh $SSH_OPTS -i $SSH_KEY ${ADMIN_USER}@${VM_IP}"
SCP_CMD="scp $SSH_OPTS -i $SSH_KEY"

mkdir -p "$OUTPUT_DIR"

echo "=== Waiting for SSH on ${VM_NAME} (${VM_IP}) ==="
for i in $(seq 1 60); do
  if $SSH_CMD true 2>/dev/null; then
    break
  fi
  if [[ $i -eq 60 ]]; then
    echo "ERROR: SSH timeout after 5 minutes" >&2
    exit 1
  fi
  sleep 5
done

echo "=== FIPS check ==="
FIPS=$($SSH_CMD "cat /proc/sys/crypto/fips_enabled")
if [[ "${FIPS}" == "1" ]]; then
  echo "PASS: FIPS enabled"
else
  echo "FAIL: FIPS NOT enabled (got: ${FIPS})"
fi

echo "=== LVM layout ==="
$SSH_CMD "sudo lvs --noheadings 2>/dev/null; echo '--- Mounts ---'; df -hT / /home /tmp /var /var/log /var/log/audit /var/tmp 2>/dev/null" || true

echo "=== Kernel cmdline ==="
$SSH_CMD "cat /proc/cmdline"

echo "=== OpenSCAP STIG scan ==="
$SSH_CMD "sudo oscap xccdf eval \
  --profile xccdf_org.ssgproject.content_profile_stig \
  --results /tmp/stig-results.xml \
  --report /tmp/stig-report.html \
  /usr/share/xml/scap/ssg/content/ssg-rhel${RHEL_VERSION}-ds.xml" || true

echo "=== STIG score ==="
$SSH_CMD "bash -c 'pass=\$(sudo grep -c \"<result>pass</result>\" /tmp/stig-results.xml 2>/dev/null || echo 0); \
  fail=\$(sudo grep -c \"<result>fail</result>\" /tmp/stig-results.xml 2>/dev/null || echo 0); \
  total=\$((pass + fail)); \
  if [ \$total -gt 0 ]; then echo \"Pass: \$pass, Fail: \$fail, Compliance: \$((pass * 100 / total))%\"; \
  else echo \"Pass: \$pass, Fail: \$fail, No results\"; fi'" || true

echo "=== Downloading reports ==="
$SSH_CMD "sudo chmod 644 /tmp/stig-report.html /tmp/stig-results.xml" 2>/dev/null || true
$SCP_CMD "${ADMIN_USER}@${VM_IP}:/tmp/stig-report.html" "${OUTPUT_DIR}/${VM_NAME}-stig-report.html" 2>/dev/null || true
$SCP_CMD "${ADMIN_USER}@${VM_IP}:/tmp/stig-results.xml" "${OUTPUT_DIR}/${VM_NAME}-stig-results.xml" 2>/dev/null || true

echo "=== Verification complete for ${VM_NAME} ==="
