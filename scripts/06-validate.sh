#!/bin/bash
# 06-validate.sh — Post-build validation gate
# Any failed check exits non-zero, which fails the Packer build entirely.
# This is your quality gate before the AMI is snapshotted.
set -euxo pipefail

echo "================================================================"
echo " STEP 6: Post-Build Validation"
echo "================================================================"

JAVA_VERSION="${JAVA_VERSION:-17}"
NODE_VERSION="${NODE_VERSION:-20}"
PASS=0
FAIL=0

check() {
  local description="$1"
  local command="$2"
  if eval "$command" > /dev/null 2>&1; then
    echo "  [PASS] $description"
    ((PASS++)) || true
  else
    echo "  [FAIL] $description"
    ((FAIL++)) || true
  fi
}

# -----------------------------------------------------------------------
# Security: SSH
# -----------------------------------------------------------------------

echo ""
echo "--- SSH Hardening ---"
check "PermitRootLogin disabled" \
  "grep -E '^PermitRootLogin no' /etc/ssh/sshd_config"
check "PasswordAuthentication disabled" \
  "grep -E '^PasswordAuthentication no' /etc/ssh/sshd_config"
check "X11Forwarding disabled" \
  "grep -E '^X11Forwarding no' /etc/ssh/sshd_config"
check "AllowTcpForwarding disabled" \
  "grep -E '^AllowTcpForwarding no' /etc/ssh/sshd_config"
check "MaxAuthTries set" \
  "grep -E '^MaxAuthTries [0-4]' /etc/ssh/sshd_config"
check "SSH host keys removed (will regenerate on boot)" \
  "[ ! -f /etc/ssh/ssh_host_rsa_key ]"

# -----------------------------------------------------------------------
# Security: kernel parameters
# -----------------------------------------------------------------------

echo ""
echo "--- Kernel Hardening ---"
check "IP forwarding disabled" \
  "[ \"\$(sysctl -n net.ipv4.ip_forward)\" = '0' ]"
check "ICMP redirects disabled" \
  "[ \"\$(sysctl -n net.ipv4.conf.all.accept_redirects)\" = '0' ]"
check "TCP SYN cookies enabled" \
  "[ \"\$(sysctl -n net.ipv4.tcp_syncookies)\" = '1' ]"
check "ASLR enabled (randomize_va_space=2)" \
  "[ \"\$(sysctl -n kernel.randomize_va_space)\" = '2' ]"
check "Martians logging enabled" \
  "[ \"\$(sysctl -n net.ipv4.conf.all.log_martians)\" = '1' ]"

# -----------------------------------------------------------------------
# Services: AWS agents
# -----------------------------------------------------------------------

echo ""
echo "--- AWS Agents ---"
check "SSM Agent: service enabled" \
  "systemctl is-enabled amazon-ssm-agent"
check "SSM Agent: service active" \
  "systemctl is-active amazon-ssm-agent"
check "CloudWatch Agent: installed" \
  "test -f /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl"
check "CloudWatch Agent: config present" \
  "test -f /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json"

# -----------------------------------------------------------------------
# App runtimes
# -----------------------------------------------------------------------

echo ""
echo "--- App Runtimes ---"
check "Java (Corretto) installed" \
  "java -version"
check "Java version matches expected (${JAVA_VERSION})" \
  "java -version 2>&1 | grep -q 'Corretto-${JAVA_VERSION}'"
check "javac available" \
  "javac -version"
check "Node.js installed" \
  "node --version"
check "Node.js major version matches (${NODE_VERSION})" \
  "node --version | grep -q '^v${NODE_VERSION}'"
check "npm available" \
  "npm --version"
check "Python3 available" \
  "python3 --version"
check "pip3 available" \
  "pip3 --version"
check "boto3 installed" \
  "python3 -c 'import boto3'"

# -----------------------------------------------------------------------
# Audit and logging
# -----------------------------------------------------------------------

echo ""
echo "--- Audit & Logging ---"
check "auditd running" \
  "systemctl is-active auditd"
check "auditd enabled at boot" \
  "systemctl is-enabled auditd"
check "Audit rules loaded" \
  "auditctl -l | grep -q 'identity'"
check "AIDE database initialised" \
  "test -f /var/lib/aide/aide.db.gz"

# -----------------------------------------------------------------------
# Filesystem
# -----------------------------------------------------------------------

echo ""
echo "--- Filesystem ---"
check "Unused filesystem modules blocked (cramfs)" \
  "grep -q 'install cramfs /bin/false' /etc/modprobe.d/cis-filesystem.conf"
check "Cloud-init will regenerate SSH keys on boot" \
  "grep -q 'ssh_deletekeys: true' /etc/cloud/cloud.cfg.d/99-golden-ami.cfg"
check "Shell history cleared" \
  "[ ! -s /root/.bash_history ]"

# -----------------------------------------------------------------------
# Golden AMI manifest exists
# -----------------------------------------------------------------------

echo ""
echo "--- AMI Manifest ---"
check "Agent manifest file exists" \
  "test -f /etc/golden-ami/agent-versions.txt"

# -----------------------------------------------------------------------
# Result summary
# -----------------------------------------------------------------------

echo ""
echo "================================================================"
echo " Validation Results: ${PASS} passed, ${FAIL} failed"
echo "================================================================"

if [ "$FAIL" -gt 0 ]; then
  echo "FATAL: ${FAIL} validation check(s) failed. Failing the Packer build."
  exit 1
fi

echo "All checks passed. AMI is ready to snapshot."
