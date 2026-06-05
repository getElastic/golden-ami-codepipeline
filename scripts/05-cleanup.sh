#!/bin/bash
# 05-cleanup.sh — Remove build artefacts, temp files, history
# Run last before snapshotting to keep the AMI clean
set -euxo pipefail

echo "================================================================"
echo " STEP 5: Cleanup"
echo "================================================================"

# -----------------------------------------------------------------------
# Package manager cache
# -----------------------------------------------------------------------

echo ">>> Cleaning dnf cache"
dnf clean all
rm -rf /var/cache/dnf /var/cache/yum

# -----------------------------------------------------------------------
# SSH host keys — regenerated on first boot
# Host keys baked into an AMI are a security risk because every instance
# launched from it would initially share the same host key fingerprint
# until cloud-init regenerates them. Remove them here.
# -----------------------------------------------------------------------

echo ">>> Removing SSH host keys (regenerated on first boot by cloud-init)"
rm -f /etc/ssh/ssh_host_*

# Ensure cloud-init will regenerate host keys on first boot
cat > /etc/cloud/cloud.cfg.d/99-golden-ami.cfg << 'EOF'
# Regenerate SSH host keys on first boot
ssh_deletekeys: true
ssh_genkeytypes: ['rsa', 'ecdsa', 'ed25519']
EOF

# -----------------------------------------------------------------------
# Shell history
# -----------------------------------------------------------------------

echo ">>> Clearing shell history"
unset HISTFILE
history -c
rm -f /root/.bash_history
rm -f /home/ec2-user/.bash_history

# Prevent future history writes during this session
export HISTSIZE=0

# -----------------------------------------------------------------------
# Temp files and logs
# -----------------------------------------------------------------------

echo ">>> Clearing temp files and build logs"
rm -rf /tmp/*
rm -rf /var/tmp/*

# Truncate (not delete) log files so services don't complain
find /var/log -type f | while read -r logfile; do
  truncate -s 0 "$logfile"
done

# -----------------------------------------------------------------------
# Cloud-init state — reset so it runs fresh on first boot
# -----------------------------------------------------------------------

echo ">>> Resetting cloud-init state"
cloud-init clean --logs --seed 2>/dev/null || true

# -----------------------------------------------------------------------
# Packer temp files
# -----------------------------------------------------------------------

echo ">>> Removing Packer temp files"
rm -f /tmp/script_*.sh
rm -f /tmp/packer-*

# -----------------------------------------------------------------------
# Package manager history
# -----------------------------------------------------------------------

rm -rf /var/log/dnf* /var/log/yum*

echo ">>> Cleanup complete"
